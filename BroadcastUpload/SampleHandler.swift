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
        guard sampleBufferType == .video || sampleBufferType == .audioMic
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
        case .audioMic:
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { return }
            // Canonical audio extraction (labels verified against the SDK
            // header): AudioBufferList + retained CMBlockBuffer.
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: 0, mData: nil))
            var block: CMBlockBuffer?
            let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &list,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &block)
            guard st == noErr, list.mBuffers.mDataByteSize > 0,
                  let data = list.mBuffers.mData
            else { return }
            writer.storeAudio(
                bytes: data,
                byteCount: Int(list.mBuffers.mDataByteSize),
                // NOTE: ReplayKit's pts is host-time seconds since boot,
                // NOT duration — numSamples/pts.seconds is dimensionally
                // wrong (yields ~0.003 Hz). Trust the buffer's own format.
                sampleRate: 48000,
                numChannels: Int(list.mBuffers.mNumberChannels),
                pts: pts)
        default:
            break
        }
    }
}
