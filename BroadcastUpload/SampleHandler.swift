import AVFoundation
import CoreAudio
import CoreMedia
import ReplayKit

/// Broadcast Upload Extension: screen frames + native ReplayKit audio
/// (app sound) into the FrameBridge. Mic is captured in the main app.
final class SampleHandler: RPBroadcastSampleHandler {

    private var writer: FrameBridge.Writer?
    private var dropped = 0
    private var startedAt = Date()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAt = Date()
        do {
            let w = try FrameBridge.Writer()
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
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard let writer else { return }
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
            if writer.videoBacklog() > 1 {
                dropped += 1
                return
            }
            guard let slot = writer.beginVideoFrame(from: buffer)
            else { return }
            writer.commitVideoFrame(slot: slot, pts: pts)
        case .audioApp:
            passThroughAudio(sampleBuffer, writer: writer, pts: pts)
        default:
            break
        }
    }

    /// Copy ReplayKit's native bytes + format. No conversion.
    private func passThroughAudio(
        _ sampleBuffer: CMSampleBuffer,
        writer: FrameBridge.Writer,
        pts: CMTime
    ) {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
        else { return }
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return }
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
        guard st == noErr else { return }
        let buf = abl.pointee.mBuffers
        guard buf.mDataByteSize > 0, let data = buf.mData else { return }
        writer.storeAudio(
            bytes: data,
            byteCount: Int(buf.mDataByteSize),
            asbd: asbd,
            pts: pts)
    }
}
