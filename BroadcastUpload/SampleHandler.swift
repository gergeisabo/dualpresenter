import AVFoundation
import CoreMedia
import ReplayKit

/// Broadcast Upload Extension: receives the raw screen frames + mic
/// audio from ReplayKit and publishes them into the shared FrameBridge
/// (mmap ring in the App Group). The main app reads the bridge live and
/// composites + writes the single output file.
///
/// Memory discipline: nothing is retained between callbacks — every
/// buffer is drawn into the ring and dropped. The 50 MB extension
/// budget stays untouched.
final class SampleHandler: RPBroadcastSampleHandler {

    private var writer: FrameBridge.Writer?
    private var dropped = 0
    private var startedAt = Date()
    private var pendingApp = [Int16]()
    private var pendingMic = [Int16]()
    private var mixPTS = CMTime.invalid
    private let mixRate = 44_100.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = Date()
        do {
            let w = try FrameBridge.Writer()
            // Fresh session: reset the ring header (seq = 0) and mark
            // started. The app-side Reader is created after this.
            w.setCommand(.started)
            writer = w
        } catch {
            finishBroadcastWithError(
                NSError(domain: "DualPresenter.BUE", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Could not open the frame bridge: \(error)"]))
        }
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        if let writer {
            flushAudio(writer, force: true)
            writer.setCommand(.ended)
        }
        writer = nil
        pendingApp.removeAll()
        pendingMic.removeAll()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard let writer else { return }
        guard sampleBufferType == .video
                || sampleBufferType == .audioMic
                || sampleBufferType == .audioApp
        else { return }

        // Orphan guard: if the app died (crash/kill), its heartbeat goes
        // stale and WE end the broadcast ourselves — no zombie recording.
        // Grace: 10s from broadcast start covers app cold-start + camera
        // permission + writer setup before the first stamp lands.
        if writer.appHeartbeatAge > 5,
           Date().timeIntervalSince(startedAt) > 10 {
            writer.setCommand(.ended)
            self.writer = nil
            finishBroadcastWithError(NSError(
                domain: RPRecordingErrorDomain,
                code: RPRecordingErrorCode.failedToStart.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "DualPresenter closed."]))
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch sampleBufferType {
        case .video:
            if writer.pendingCommand == .stopRequested {
                writer.setCommand(.ended)
                self.writer = nil
                return
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            // The app consumes at most ~30 fps; screen capture delivers
            // up to 60. Drop extras at the source to halve ring traffic.
            if writer.videoBacklog() > 1 {
                dropped += 1
                return
            }
            guard let slot = writer.beginVideoFrame(from: buffer)
            else { return }
            writer.commitVideoFrame(slot: slot, pts: pts)
        case .audioMic, .audioApp:
            ingestAudio(sampleBuffer, isMic: sampleBufferType == .audioMic, writer: writer, pts: pts)
        default:
            break
        }
    }

    /// Decode ReplayKit audio (float or int, any rate/channel count) to
    /// 44.1 kHz mono Int16, mix mic + app, write in 8 KB ring slots.
    private func ingestAudio(
        _ sampleBuffer: CMSampleBuffer,
        isMic: Bool,
        writer: FrameBridge.Writer,
        pts: CMTime
    ) {
        guard let pcm = decodeToMonoInt16(sampleBuffer) else { return }
        if !mixPTS.isValid { mixPTS = pts }
        if isMic { pendingMic.append(contentsOf: pcm) }
        else { pendingApp.append(contentsOf: pcm) }
        flushAudio(writer, force: false)
    }

    private func flushAudio(_ writer: FrameBridge.Writer, force: Bool) {
        let hold = Int(mixRate * 0.02)
        while true {
            let nMix = min(pendingApp.count, pendingMic.count)
            if nMix > 0 {
                var mixed = [Int16](repeating: 0, count: nMix)
                for i in 0..<nMix {
                    let s = Int(pendingApp[i]) + Int(pendingMic[i])
                    mixed[i] = Int16(clamping: s)
                }
                pendingApp.removeFirst(nMix)
                pendingMic.removeFirst(nMix)
                writePCM(mixed, writer: writer)
                continue
            }
            let alone = pendingMic.isEmpty ? pendingApp : pendingApp.isEmpty ? pendingMic : [Int16]()
            if alone.isEmpty { break }
            if !force && alone.count <= hold { break }
            writePCM(alone, writer: writer)
            if pendingMic.isEmpty { pendingApp.removeAll() }
            else { pendingMic.removeAll() }
            break
        }
    }

    private func writePCM(_ pcm: [Int16], writer: FrameBridge.Writer) {
        guard !pcm.isEmpty else { return }
        let maxSamples = FrameBridge.audioSlotBytes / 2
        var offset = 0
        var t = mixPTS
        while offset < pcm.count {
            let n = min(maxSamples, pcm.count - offset)
            pcm.withUnsafeBufferPointer { buf in
                writer.storeAudio(
                    bytes: buf.baseAddress! + offset,
                    byteCount: n * 2,
                    sampleRate: mixRate,
                    numChannels: 1,
                    pts: t)
            }
            offset += n
            t = t + CMTime(value: CMTimeValue(n), timescale: CMTimeScale(mixRate))
        }
        mixPTS = t
    }

    private func decodeToMonoInt16(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        else { return nil }
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : mixRate
        let ch = max(1, Int(asbd.mChannelsPerFrame))
        let bytesPerFrame = max(1, Int(asbd.mBytesPerFrame))
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: abl, bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block)
        guard st == noErr else { return nil }
        let buf = abl.pointee.mBuffers
        guard buf.mDataByteSize > 0, let data = buf.mData else { return nil }
        let frames = Int(buf.mDataByteSize) / bytesPerFrame
        guard frames > 0 else { return nil }

        var mono = [Int16](repeating: 0, count: frames)
        if isFloat {
            let src = data.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += src[i * ch + c] }
                acc /= Float(ch)
                mono[i] = Int16(max(-1, min(1, acc)) * Float(Int16.max))
            }
        } else {
            let src = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<frames {
                var acc = 0
                for c in 0..<ch { acc += Int(src[i * ch + c]) }
                mono[i] = Int16(acc / ch)
            }
        }
        if abs(rate - mixRate) < 1 { return mono }
        return resample(mono, from: rate, to: mixRate)
    }

    private func resample(_ input: [Int16], from: Double, to: Double) -> [Int16] {
        guard !input.isEmpty, from > 0 else { return input }
        let outCount = max(1, Int((Double(input.count) * to / from).rounded()))
        var out = [Int16](repeating: 0, count: outCount)
        let step = from / to
        for i in 0..<outCount {
            let src = Double(i) * step
            let i0 = min(input.count - 1, max(0, Int(src)))
            let i1 = min(input.count - 1, i0 + 1)
            let frac = src - Double(i0)
            out[i] = Int16(
                Double(input[i0]) * (1 - frac) + Double(input[i1]) * frac)
        }
        return out
    }
}
