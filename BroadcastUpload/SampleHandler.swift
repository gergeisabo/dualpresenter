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
        writer?.setCommand(.ended)
        writer = nil
        // Keep the ring readable so the app can drain the tail.
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
            storeAudio(sampleBuffer, writer: writer, pts: pts)
        default:
            break
        }
    }

    /// ReplayKit may deliver Float32 or Int16. Always store packed Int16
    /// so the app-side writer has a known format. Uses the buffer's own
    /// sample rate (not a hardcoded 48000).
    private func storeAudio(
        _ sampleBuffer: CMSampleBuffer,
        writer: FrameBridge.Writer,
        pts: CMTime
    ) {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        var rate = 44_100.0
        var channels = 1
        var isFloat = false
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            channels = max(1, Int(asbd.mChannelsPerFrame))
            isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        }

        var listSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil)
        guard listSize > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &block)
        guard st == noErr else { return }
        let buf = abl.pointee.mBuffers
        guard buf.mDataByteSize > 0, let data = buf.mData else { return }
        let inChannels = max(1, Int(buf.mNumberChannels == 0 ? channels : Int(buf.mNumberChannels)))

        // Downmix to mono Int16 for the ring.
        var pcm = [Int16](repeating: 0, count: numSamples)
        if isFloat {
            let src = data.assumingMemoryBound(to: Float.self)
            for i in 0..<numSamples {
                var acc: Float = 0
                for c in 0..<inChannels { acc += src[i * inChannels + c] }
                acc /= Float(inChannels)
                let clipped = max(-1, min(1, acc))
                pcm[i] = Int16(clipped * Float(Int16.max))
            }
        } else {
            let src = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<numSamples {
                var acc = 0
                for c in 0..<inChannels { acc += Int(src[i * inChannels + c]) }
                pcm[i] = Int16(acc / inChannels)
            }
        }
        pcm.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            writer.storeAudio(
                bytes: ptr,
                byteCount: pcm.count * 2,
                sampleRate: rate,
                numChannels: 1,
                pts: pts)
        }
    }
}
