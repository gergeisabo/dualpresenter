import AVFoundation
import Combine
import CoreMedia
import UIKit

/// Dual-camera capture engine (M1 "Dual Cam" mode).
///
/// One `AVCaptureMultiCamSession` with front + back cameras + mic. Video and
/// audio flow through data outputs into two independent `AVAssetWriter`
/// pipelines that write separate H.264 .mp4 files to the temp directory.
/// The composite step is offline (record-then-composite — see Compositor).
///
/// Mirroring: WYSIWYG per plan — the front data connection is mirrored, so
/// the front file is baked mirrored exactly as the preview shows it.
///
/// Threading: all mutable state lives on `sessionQueue` (phase/writers) or
/// the main thread (@Published). Delegate callbacks hop onto sessionQueue.
/// The class is @unchecked Sendable by that convention, not by data-race
/// freedom of arbitrary field access.
final class DualCamRecorder: NSObject, ObservableObject, @unchecked Sendable {

    enum State: Equatable {
        case idle            // configured, previewing, ready to record
        case settingUp
        case recording
        case finishing
        case finished(front: URL, back: URL)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var ready = false   // true once previews can attach

    let session = AVCaptureMultiCamSession()

    // SessionQueue-confined below.
    enum Phase { case idle, configuring, ready, recording, finishing }
    private var phase: Phase = .idle

    private let sessionQueue = DispatchQueue(label: "dualpresenter.session")
    private let videoQueue = DispatchQueue(label: "dualpresenter.video")
    private let audioQueue = DispatchQueue(label: "dualpresenter.audio")

    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var configured = false

    private var backWriter: AVAssetWriter?
    private var backVideoInput: AVAssetWriterInput?
    private var backAudioInput: AVAssetWriterInput?
    private var backAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var backURL: URL?
    private var backWriterStarted = false

    private var frontWriter: AVAssetWriter?
    private var frontVideoInput: AVAssetWriterInput?
    private var frontAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frontURL: URL?
    private var frontWriterStarted = false

    /// Shared anchor: the PTS of the first video sample. Both writers start
    /// their sessions at this instant so the two files share one timeline.
    private var sessionStartTime: CMTime = .invalid

    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?

    // MARK: - Setup

    func setUp() {
        sessionQueue.async { [self] in
            guard !configured, phase == .idle || phase == .ready else { return }
            phase = .configuring
        }
        publish(.settingUp)

        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                self.sessionQueue.async {
                    guard videoOK, audioOK else {
                        self.fail("Camera and microphone access are required.")
                        return
                    }
                    self.configureSession()
                }
            }
        }
    }

    private func configureSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            fail("Dual camera capture is not supported on this device.")
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            configured = true
        }

        guard
            let backCamera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back),
            let frontCamera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front),
            let mic = AVCaptureDevice.default(for: .audio),
            let theBackInput = try? AVCaptureDeviceInput(device: backCamera),
            let theFrontInput = try? AVCaptureDeviceInput(device: frontCamera),
            let micInput = try? AVCaptureDeviceInput(device: mic)
        else {
            fail("Could not access the cameras or microphone.")
            return
        }

        for input in [theBackInput, theFrontInput, micInput] where session.canAddInput(input) {
            session.addInput(input)
        }
        backInput = theBackInput
        frontInput = theFrontInput

        // Formats: multicam-legal subset only (research: strict subset of all
        // formats). Back 1080p30, front 720p30 — the WWDC19-249 hardware budget.
        backCamera.applyMultiCamFormat(minWidth: 1920, minHeight: 1080)
        frontCamera.applyMultiCamFormat(minWidth: 1280, minHeight: 720)

        backVideoOutput.videoSettings = nil   // native buffers out
        frontVideoOutput.videoSettings = nil
        backVideoOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
        backVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        frontVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        for output: AVCaptureOutput in [backVideoOutput, frontVideoOutput, audioOutput]
        where session.canAddOutput(output) {
            session.addOutput(output)
        }

        // Portrait (90°) via the modern API; mirroring explicit per plan:
        // front file + preview mirrored, back untouched.
        if let c = backVideoOutput.connection(with: .video) {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
        if let c = frontVideoOutput.connection(with: .video) {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }

        session.startRunning()

        DispatchQueue.main.async { self.ready = true }
        phase = .ready
        publish(.idle)
    }

    // MARK: - Recording

    func startRecording() {
        sessionQueue.async { [self] in
            guard phase == .ready else { return }
            do {
                let back = try makeWriter(bitRate: 10_000_000, audio: true)
                backWriter = back.writer
                backVideoInput = back.video
                backAudioInput = back.audio
                backAdaptor = back.adaptor
                backURL = back.url
                let front = try makeWriter(bitRate: 5_000_000, audio: false)
                frontWriter = front.writer
                frontVideoInput = front.video
                frontAdaptor = front.adaptor
                frontURL = front.url
                sessionStartTime = .invalid
                backWriterStarted = false
                frontWriterStarted = false
                phase = .recording
                publish(.recording)
                startTimer()
            } catch {
                teardownWriters(cancel: true)
                phase = .ready
                publish(.error("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            guard phase == .recording else { return }
            phase = .finishing
            publish(.finishing)
            stopTimer()
            backVideoInput?.markAsFinished()
            frontVideoInput?.markAsFinished()
            backAudioInput?.markAsFinished()
            backWriter?.finishWriting { self.finishFrontThenComplete() }
        }
    }

    private func finishFrontThenComplete() {
        sessionQueue.async { [self] in
            guard let front = frontWriter else { complete() ; return }
            front.finishWriting {
                self.sessionQueue.async { self.complete() }
            }
        }
    }

    private func complete() {
        let ok = backWriter?.status == .completed && frontWriter?.status == .completed
        let urls = (front: frontURL, back: backURL)
        teardownWriters(cancel: false)
        phase = .ready
        if ok, let f = urls.front, let b = urls.back {
            publish(.finished(front: f, back: b))
        } else {
            publish(.error("The recording could not be saved."))
        }
    }

    // MARK: - Writers

    private func makeWriter(
        bitRate: Int, audio: Bool
    ) throws -> (writer: AVAssetWriter, video: AVAssetWriterInput,
                 audio: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                 url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // No width/height in settings: they are taken from the appended
        // buffers, so they always match the rotated camera output.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 32_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        return (writer, video, audioInput, adaptor, url)
    }

    private func teardownWriters(cancel: Bool) {
        if cancel {
            backWriter?.cancelWriting()
            frontWriter?.cancelWriting()
            try? FileManager.default.removeItem(at: backURL!)
            try? FileManager.default.removeItem(at: frontURL!)
        }
        backWriter = nil; frontWriter = nil
        backVideoInput = nil; frontVideoInput = nil; backAudioInput = nil
        backAdaptor = nil; frontAdaptor = nil
        backURL = nil; frontURL = nil
        backWriterStarted = false; frontWriterStarted = false
        sessionStartTime = .invalid
    }

    // MARK: - Sample handling (all on sessionQueue)

    private func handle(_ sampleBuffer: CMSampleBuffer, isVideo: Bool, isBack: Bool) {
        guard phase == .recording else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if isVideo {
            if !sessionStartTime.isValid { sessionStartTime = pts }
        }
        guard sessionStartTime.isValid, CMTimeCompare(pts, sessionStartTime) >= 0 else { return }

        if isVideo, isBack {
            guard let writer = backWriter, let input = backVideoInput,
                  let adaptor = backAdaptor else { return }
            if !backWriterStarted {
                writer.startSession(atSourceTime: sessionStartTime)
                backWriterStarted = true
            }
            guard input.isReadyForMoreMediaData,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                fail("Could not write back-camera video.")
            }
        } else if isVideo {
            guard let writer = frontWriter, let input = frontVideoInput,
                  let adaptor = frontAdaptor else { return }
            if !frontWriterStarted {
                writer.startSession(atSourceTime: sessionStartTime)
                frontWriterStarted = true
            }
            guard input.isReadyForMoreMediaData,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                fail("Could not write front-camera video.")
            }
        } else {
            guard let writer = backWriter, let input = backAudioInput else { return }
            if !backWriterStarted {
                writer.startSession(atSourceTime: sessionStartTime)
                backWriterStarted = true
            }
            guard input.isReadyForMoreMediaData else { return }
            if !input.append(sampleBuffer) {
                fail("Could not write audio.")
            }
        }
    }

    // MARK: - Timer / state helpers

    private func startTimer() {
        DispatchQueue.main.async { [self] in
            startedAt = Date()
            elapsed = 0
            timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self, let started = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(started)
                }
        }
    }

    private func stopTimer() {
        DispatchQueue.main.async { [self] in
            timerCancellable?.cancel()
            timerCancellable = nil
        }
    }

    /// Call on sessionQueue (or hop there first).
    private func fail(_ message: String) {
        stopTimer()
        teardownWriters(cancel: true)
        phase = .ready
        publish(.error(message))
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: - Preview ports (read after `ready == true`)

    var backPreviewPort: AVCaptureInput.Port? {
        backInput?.ports.first { $0.mediaType == .video }
    }

    var frontPreviewPort: AVCaptureInput.Port? {
        frontInput?.ports.first { $0.mediaType == .video }
    }
}

// MARK: - Capture delegates (thin forwarder onto sessionQueue)
// One method satisfies BOTH protocols — the signatures are identical, so
// separate declarations would be an invalid redeclaration.

extension DualCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            sessionQueue.async {
                self.handle(sampleBuffer, isVideo: false, isBack: false)
            }
        } else {
            let isBack = output === self.backVideoOutput
            sessionQueue.async {
                self.handle(sampleBuffer, isVideo: true, isBack: isBack)
            }
        }
    }
}

// MARK: - Format picking

private extension AVCaptureDevice {
    /// Smallest multicam-legal format that covers the preferred size, pinned
    /// to 30 fps. No-op when nothing matches (defaults stay).
    func applyMultiCamFormat(minWidth: Int32, minHeight: Int32) {
        let candidates = formats.filter { $0.isMultiCamSupported }
        let match = candidates
            .filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width >= minWidth && d.height >= minHeight
            }
            .min { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return da.width * da.height < db.width * db.height
            }
        guard let match else { return }
        do {
            try lockForConfiguration()
            activeFormat = match
            if match.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }) {
                activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            unlockForConfiguration()
        } catch {
            // Keep whatever format is active — recording still works.
        }
    }
}
