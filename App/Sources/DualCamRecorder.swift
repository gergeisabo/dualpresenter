import AVFoundation
import Combine
import CoreMedia
import Photos
import UIKit

/// Dual-camera capture engine (M1 "Dual Cam" mode), RØDE-Combined-style:
/// back camera full-frame + front-camera bubble drawn into ONE video file
/// live while recording. Stop = finished file, no post-processing.
///
/// One `AVCaptureMultiCamSession`, front + back cameras + mic. Data outputs
/// deliver frames; every back frame is composited with the latest front
/// frame via `LiveCombine` into a single 1080x1920 BGRA buffer and appended
/// to one `AVAssetWriter` (H.264 + AAC .mp4).
///
/// Threading: mutable state on `sessionQueue`; @Published on main.
/// Delegate callbacks hop onto sessionQueue.
final class DualCamRecorder: NSObject, ObservableObject, @unchecked Sendable {

    enum State: Equatable {
        case idle            // configured, previewing, ready to record
        case settingUp
        case recording
        case finished(URL)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var ready = false   // true once previews can attach
    /// Current bubble placement, canvas-normalized. Set by the UI (drags);
    /// read on the video queue for each combined frame — WYSIWYG.
    var bubblePlacement: BubblePlacement = .standard

    let session = AVCaptureMultiCamSession()

    // sessionQueue-confined below.
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

    // The ONE combined output file.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var writerStarted = false     // startSession called
    private var sessionStartTime: CMTime = .invalid
    private var lastVideoPTS: CMTime?
    private var lastAudioPTS: CMTime?

    // Latest front frame for the bubble (replaced as they arrive).
    private var latestFront: CVPixelBuffer?

    // Recycled combined-frame buffer pool.
    private var destPool: CVPixelBufferPool?

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

        session.beginConfiguration()

        for input in [theBackInput, theFrontInput, micInput] where session.canAddInput(input) {
            session.addInput(input)
        }
        backInput = theBackInput
        frontInput = theFrontInput

        // Formats: multicam-legal subset only. Back 1080p30, front 720p30 —
        // the WWDC19-249 hardware budget.
        backCamera.applyMultiCamFormat(minWidth: 1920, minHeight: 1080)
        frontCamera.applyMultiCamFormat(minWidth: 1280, minHeight: 720)

        // BGRA so frames can be drawn via CoreGraphics without conversion.
        let bgra: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        backVideoOutput.videoSettings = bgra
        frontVideoOutput.videoSettings = bgra
        backVideoOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true
        backVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        frontVideoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        for output: AVCaptureOutput in [backVideoOutput, frontVideoOutput, audioOutput]
        where session.canAddOutput(output) {
            session.addOutput(output)
        }

        // Portrait (90°) via the modern API; mirroring explicit:
        // front bubble mirrored like a mirror preview, back untouched.
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

        session.commitConfiguration()

        // Start ONLY after commitConfiguration — calling startRunning
        // between begin/commit throws NSGenericException (device crash 153502).
        session.startRunning()

        // Pool for the combined 1080x1920 BGRA frames.
        destPool = LiveCombine.makeBufferPool()

        configured = true
        DispatchQueue.main.async { self.ready = true }
        phase = .ready
        publish(.idle)
    }

    // MARK: - Recording

    func startRecording() {
        sessionQueue.async { [self] in
            guard phase == .ready else { return }
            do {
                let made = try makeWriter()
                writer = made.writer
                videoInput = made.video
                audioInput = made.audio
                adaptor = made.adaptor
                outputURL = made.url
                sessionStartTime = .invalid
                writerStarted = false
                lastVideoPTS = nil
                lastAudioPTS = nil
                latestFront = nil
                // Writers MUST enter .writing before startSession(atSourceTime:)
                // (device crash 160528: "Cannot call method when status is 0").
                writer?.startWriting()
                phase = .recording
                publish(.recording)
                startTimer()
            } catch {
                teardownWriter(cancel: true)
                phase = .ready
                publish(.error("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            guard phase == .recording else { return }
            phase = .finishing
            stopTimer()
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer?.finishWriting {
                self.sessionQueue.async { self.complete() }
            }
        }
    }

    private func complete() {
        let ok = writer?.status == .completed
        let url = outputURL
        teardownWriter(cancel: false)
        phase = .ready
        if ok, let url {
            PhotosSaver.saveVideo(url) { _ in }
            publish(.finished(url))
        } else {
            publish(.error("The recording could not be saved."))
        }
    }

    // MARK: - Writer

    private func makeWriter() throws -> (writer: AVAssetWriter,
                                         video: AVAssetWriterInput,
                                         audio: AVAssetWriterInput,
                                         adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                         url: URL) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DP-\(UUID().uuidString)").appendingPathExtension("mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Width/height are REQUIRED on iOS 18 — omitting them throws
        // "Missing required key AVVideoHeightKey" (device crash 155017).
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        w.add(video)

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 32_000,
        ])
        audio.expectsMediaDataInRealTime = true
        w.add(audio)

        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        return (w, video, audio, ad, url)
    }

    private func teardownWriter(cancel: Bool) {
        if cancel {
            writer?.cancelWriting()
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
        outputURL = nil
        writerStarted = false
        lastVideoPTS = nil
        lastAudioPTS = nil
        sessionStartTime = .invalid
        latestFront = nil
    }

    // MARK: - Sample handling (all on sessionQueue)

    private func handleVideo(_ sampleBuffer: CMSampleBuffer, isBack: Bool) {
        guard phase == .recording else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !isBack {
            latestFront = pixelBuffer
            return
        }

        // Back frame = the clock. Composite + append.
        guard let writer, let videoInput, let adaptor else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStartTime.isValid { sessionStartTime = pts }
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
        if let last = lastVideoPTS, CMTimeCompare(pts, last) <= 0 { return }
        lastVideoPTS = pts

        guard videoInput.isReadyForMoreMediaData else { return }
        guard let pool = destPool else { return }

        var destMaybe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destMaybe)
        guard let dest = destMaybe else { return }

        CVPixelBufferLockBaseAddress(dest, [])
        let placement = bubblePlacement
        LiveCombine.draw(
            back: pixelBuffer, front: latestFront,
            placement: placement, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        if !writerStarted {
            writer.startSession(atSourceTime: pts)
            writerStarted = true
        }
        if !adaptor.append(dest, withPresentationTime: pts) {
            fail("Could not write video.")
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard phase == .recording else { return }
        guard let writer, let audioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sessionStartTime.isValid,
              CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
        if let last = lastAudioPTS, CMTimeCompare(pts, last) <= 0 { return }
        lastAudioPTS = pts
        if !writerStarted {
            writer.startSession(atSourceTime: pts)
            writerStarted = true
        }
        guard audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(sampleBuffer) {
            fail("Could not write audio.")
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
        teardownWriter(cancel: true)
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

extension DualCamRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            sessionQueue.async {
                self.handleAudio(sampleBuffer)
            }
        } else {
            let isBack = output === self.backVideoOutput
            sessionQueue.async {
                self.handleVideo(sampleBuffer, isBack: isBack)
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
