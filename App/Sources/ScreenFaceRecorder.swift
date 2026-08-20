import AVFoundation
import AVKit
import Combine
import CoreMedia
import ReplayKit
import UIKit

/// M2 "Screen + Face" engine (Zoom-style), no-gluing edition.
///
/// The Broadcast Upload Extension (separate process) captures the screen
/// + mic and publishes frames into the shared FrameBridge (mmap ring in
/// the App Group). This class:
///   1. shows the broadcast picker, then starts the broadcast;
///   2. starts the front camera (kept alive in background via PiP);
///   3. polls the bridge, composites screen frame + face bubble LIVE
///      through the same LiveCombine engine as M1, and writes ONE file.
///
/// The user presents in any app; stop = red pill or return to the app;
/// the file is already finished. No post-processing.
final class ScreenFaceRecorder: NSObject, ObservableObject, @unchecked Sendable {

    enum State: Equatable {
        case idle
        case picking          // system broadcast sheet is up
        case armed            // broadcast live, face bubble shown, not recording
        case recording
        case finished(URL)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var faceReady = false

    /// Face bubble placement, canvas-normalized — same convention as M1.
    var bubblePlacement: BubblePlacement = .standard

    let session = AVCaptureSession()

    // sessionQueue-confined below (bridge polling reads only snapshots).
    private let sessionQueue = DispatchQueue(label: "dualpresenter.sf.session")
    private let videoQueue = DispatchQueue(label: "dualpresenter.sf.video")
    private let bridgeQueue = DispatchQueue(label: "dualpresenter.sf.bridge")

    private var broadcastController: RPBroadcastController?
    private var faceInput: AVCaptureDeviceInput?
    private let faceOutput = AVCaptureVideoDataOutput()
    private var faceConfigured = false
    private var latestFace: CVPixelBuffer?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioConverter: AVAudioConverter?
    private var audioOutputFormat: AVAudioFormat?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var writerStarted = false
    private var sessionStartTime: CMTime = .invalid
    private var phase: Phase = .idle
    enum Phase { case idle, armed, recording, finishing }

    private let destPool = LiveCombine.makeBufferPool()

    // Bridge reader is created on sessionQueue but polled on bridgeQueue
    // ONLY (single dedicated queue — no cross-queue access).
    private var reader: FrameBridge.Reader?
    private var pollSource: DispatchSourceTimer?

    // PiP facecam
    private var pipController: AVPictureInPictureController?
    private var pipDisplayLayer: AVSampleBufferDisplayLayer?
    private var pipWindow: UIWindow?
    private var pipHost: UIView?

    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?

    // MARK: - Broadcast picker

    /// Presents the system broadcast picker. Call from the UI.
    func pickAndStart() {
        switch state {
        case .idle, .error: break
        default: return
        }
        publish(.picking)
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        RPBroadcastActivityViewController.load(
            withPreferredExtension: "\(bundleID).BroadcastUpload"
        ) { [weak self] viewController, error in
            guard let self else { return }
            guard let viewController else {
                self.publish(.error(
                    "Could not open the broadcast picker: \(error?.localizedDescription ?? "unknown error")"))
                return
            }
            viewController.delegate = self
            DispatchQueue.main.async {
                // Present from the TOP-MOST controller. ScreenFaceScreen is
                // itself a full-screen cover over the root — presenting
                // from root while a cover is up is silently ignored.
                let base = UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .compactMap { $0.rootViewController }
                    .first
                var top = base
                while let presented = top?.presentedViewController {
                    top = presented
                }
                top?.present(viewController, animated: true)
            }
        }
    }

    private func startBroadcast(controller: RPBroadcastController) {
        broadcastController = controller
        controller.startBroadcast { [weak self] error in
            guard let self else { return }
            if let error {
                self.publish(.error("Could not start broadcast: \(error.localizedDescription)"))
                return
            }
            self.beginArmed()
        }
    }

    /// Broadcast is live: connect the bridge, start the face camera.
    private func beginArmed() {
        sessionQueue.async { [self] in
            do {
                reader = try FrameBridge.Reader()
            } catch {
                publish(.error("Screen capture connection failed."))
                return
            }
            configureFaceIfNeeded()
            phase = .armed
            publish(.armed)
        }
    }

    // MARK: - Face camera (front, portrait, mirrored)

    private func configureFaceIfNeeded() {
        guard !faceConfigured else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publish(.error("Camera access is required."))
                return
            }
            self.sessionQueue.async { self.configureFace() }
        }
    }

    private func configureFace() {
        guard
            let front = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: front)
        else {
            publish(.error("Could not access the front camera."))
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) {
            session.addInput(input)
            faceInput = input
        }
        faceOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        faceOutput.alwaysDiscardsLateVideoFrames = true
        faceOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(faceOutput) {
            session.addOutput(faceOutput)
        }
        session.commitConfiguration()

        if let c = faceOutput.connection(with: .video) {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }

        // Start ONLY after commitConfiguration (crash lesson 153502).
        session.startRunning()
        faceConfigured = true
        DispatchQueue.main.async { self.faceReady = true }
    }

    /// Front-camera preview port for the on-screen bubble (armed phase).
    var facePreviewPort: AVCaptureInput.Port? {
        faceInput?.ports.first { $0.mediaType == .video }
    }

    // MARK: - Recording

    func startRecording() {
        sessionQueue.async { [self] in
            guard phase == .armed else { return }
            do {
                let made = try makeWriter()
                writer = made.writer
                videoInput = made.video
                audioInput = made.audio
                adaptor = made.adaptor
                outputURL = made.url
                sessionStartTime = .invalid
                writerStarted = false
                latestFace = nil
                audioConverter = nil
                audioOutputFormat = nil
                // Writers MUST enter .writing before startSession
                // (crash lesson 160528).
                writer?.startWriting()
                phase = .recording
                publish(.recording)
                startTimer()
                startPolling()
                DispatchQueue.main.async { self.startPiPIfNeeded() }
            } catch {
                teardownWriter(cancel: true)
                phase = .armed
                publish(.error("Could not start recording: \(error.localizedDescription)"))
            }
        }
    }

    func stopRecording() {
        finishNow()
    }

    /// Single stop path for every trigger (in-app Stop, extension stop,
    /// broadcast ended). Safe to call multiple times.
    private func finishNow() {
        sessionQueue.async { [self] in
            guard phase == .recording else { return }
            phase = .finishing
            stopTimer()
            stopPolling()
            stopPiP()
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer?.finishWriting {
                self.sessionQueue.async { self.complete() }
            }
        }
    }

    private func endBroadcast() {
        broadcastController?.finishBroadcast { _ in }
        broadcastController = nil
    }

    private func complete() {
        let ok = writer?.status == .completed
        let url = outputURL
        teardownWriter(cancel: false)
        endBroadcast()
        phase = .idle
        reader = nil
        if ok, let url {
            publish(.finished(url))
        } else {
            publish(.error("The recording could not be saved."))
        }
    }

    // MARK: - Bridge polling + live composite
    //
    // pollBridge runs on bridgeQueue and is the ONLY place that touches
    // the reader. Compositing/writing hops to sessionQueue with copies.

    private func startPolling() {
        let source = DispatchSource.makeTimerSource(queue: bridgeQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10))
        source.setEventHandler { [weak self] in self?.pollBridge() }
        source.resume()
        pollSource = source
    }

    private func stopPolling() {
        pollSource?.cancel()
        pollSource = nil
    }

    private func pollBridge() {
        guard let reader else { return }
        guard phase == .recording || phase == .finishing else { return }

        // Command channel: extension-side stop (red pill / Control Center
        // is delivered to the RPBroadcastController delegate instead).
        if reader.command == .stopRequested || reader.command == .ended {
            DispatchQueue.main.async { [weak self] in self?.finishNow() }
            return
        }

        guard let frame = reader.pollVideo() else { return }
        let audio = reader.pollAudio()

        sessionQueue.async { [self] in
            appendVideo(frame)
            for chunk in audio {
                appendAudio(chunk)
            }
        }
    }

    private func appendVideo(_ frame: FrameBridge.VideoFrame) {
        guard phase == .recording else { return }
        guard let writer, let videoInput, let adaptor else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        let pts = frame.pts
        if !sessionStartTime.isValid { sessionStartTime = pts }
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }

        guard let pool = destPool else { return }
        var destMaybe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destMaybe)
        guard let dest = destMaybe else { return }

        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(
            back: frame.pixelBuffer, front: latestFace,
            placement: bubblePlacement, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        if !writerStarted {
            writer.startSession(atSourceTime: pts)
            writerStarted = true
        }
        if !adaptor.append(dest, withPresentationTime: pts) {
            fail("Could not write video.")
        }
    }

    private func appendAudio(_ chunk: FrameBridge.AudioChunk) {
        guard phase == .recording else { return }
        guard let audioInput else { return }
        guard audioInput.isReadyForMoreMediaData else { return }

        // First chunk defines the PCM format we convert everything to.
        if audioConverter == nil {
            var src = AudioStreamBasicDescription(
                mSampleRate: chunk.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: 0x0c,   // packed | signed integer
                mBytesPerPacket: UInt32(chunk.channels * 2),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(chunk.channels * 2),
                mChannelsPerFrame: UInt32(chunk.channels),
                mBitsPerChannel: 16, mReserved: 0)
            guard src.mSampleRate > 0 else { return }
            let srcPtr = withUnsafePointer(to: &src) { $0 }
            guard let inFormat = AVAudioFormat(streamDescription: srcPtr)
            else { return }
            var dst = AudioStreamBasicDescription(
                mSampleRate: src.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: 0x0c,   // packed | signed integer
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            let dstPtr = withUnsafePointer(to: &dst) { $0 }
            guard let outFormat = AVAudioFormat(streamDescription: dstPtr)
            else { return }
            audioConverter = AVAudioConverter(from: inFormat, to: outFormat)
            audioOutputFormat = outFormat
        }
        guard let converter = audioConverter,
              let outFormat = audioOutputFormat
        else { return }

        let pts = chunk.pts
        if !sessionStartTime.isValid { sessionStartTime = pts }
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }

        let frames = chunk.frameCount
        guard frames > 0,
              chunk.data.count >= frames * chunk.channels * 2
        else { return }
        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: converter.inputFormat,
            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        chunk.data.withUnsafeBytes { raw in
            if let src = raw.baseAddress,
               let dst = inBuf.int16ChannelData?[0] {
                memcpy(dst, src, frames * chunk.channels * 2)
            }
        }

        let ratio = converter.outputFormat.sampleRate
            / converter.inputFormat.sampleRate
        let cap = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outFormat, frameCapacity: cap)
        else { return }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: outBuf, error: &conversionError) {
            _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuf
        }
        if let conversionError {
            fail("Audio conversion failed.")
            return
        }
        guard outBuf.frameLength > 0,
              let sample = makeSampleBuffer(
                from: outBuf, pts: pts, format: outFormat)
        else { return }

        if !writerStarted, let writer {
            writer.startSession(atSourceTime: pts)
            writerStarted = true
        }
        if !audioInput.append(sample) {
            fail("Could not write audio.")
        }
    }

    /// Canonical PCM → CMSampleBuffer: heap block handed to a
    /// CMBlockBuffer (which owns/frees it), then an audio sample buffer
    /// with one timing entry.
    private func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer, pts: CMTime, format: AVAudioFormat
    ) -> CMSampleBuffer? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0,
              let pcm = buffer.int16ChannelData?[0]
        else { return nil }
        let bytes = frameCount * 2
        let mem = UnsafeMutableRawPointer.allocate(
            byteCount: bytes, alignment: 16)
        memcpy(mem, pcm, bytes)

        var block: CMBlockBuffer?
        let st0 = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: UInt32(bytes),
            flags: 0,
            blockBufferOut: &block)
        guard st0 == kCMBlockBufferNoErr, let blk = block else {
            mem.deallocate()
            return nil
        }
        // On success the block buffer owns `mem` and frees it.
        let st1 = CMBlockBufferAppendMemoryBlock(
            blk,
            memoryBlock: mem,
            length: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0)
        guard st1 == kCMBlockBufferNoErr else {
            mem.deallocate()
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(
                value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let st2 = withUnsafePointer(to: &timing) { timingPtr in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blk,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format.formatDescription,
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: timingPtr,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sbuf)
        }
        guard st2 == noErr else { return nil }
        return sbuf
    }

    // MARK: - Writer (same shape as M1: H.264 1080x1920 + AAC)

    private func makeWriter() throws -> (writer: AVAssetWriter,
                                         video: AVAssetWriterInput,
                                         audio: AVAssetWriterInput,
                                         adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                         url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Width/height REQUIRED on iOS 18 (crash lesson 155017).
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
        sessionStartTime = .invalid
        latestFace = nil
        audioConverter = nil
        audioOutputFormat = nil
    }

    // MARK: - PiP facecam (Zoom's pattern: keeps camera alive in bg)

    private func startPiPIfNeeded() {
        guard AVPictureInPictureController.isPictureInPictureSupported()
        else { return }

        let layer = AVSampleBufferDisplayLayer()
        let controller: AVPictureInPictureController
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipDisplayLayer = layer
        pipController = controller

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let host = UIView()
        host.frame = CGRect(x: -400, y: -400, width: 180, height: 320)
        layer.frame = host.bounds
        layer.videoGravity = .resizeAspect
        host.layer.addSublayer(layer)
        window.addSubview(host)
        window.isHidden = false
        pipWindow = window
        pipHost = host

        // Active playback audio session is required for background PiP.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        controller.startPictureInPicture()
    }

    private func stopPiP() {
        pipController?.stopPictureInPicture()
        pipController = nil
        pipDisplayLayer?.flush()
        pipDisplayLayer = nil
        pipHost?.removeFromSuperview()
        pipHost = nil
        pipWindow?.isHidden = true
        pipWindow = nil
    }

    /// Called on videoQueue with the latest face frame: feeds both the
    /// recorder and the PiP display layer.
    private func handleFaceFrame(
        _ pixelBuffer: CVPixelBuffer, pts: CMTime
    ) {
        latestFace = pixelBuffer
        guard let layer = pipDisplayLayer else { return }
        guard let sbuf = makeVideoSampleBuffer(
            from: pixelBuffer, pts: pts) else { return }
        layer.enqueue(sbuf)
    }

    /// CVPixelBuffer → CMSampleBuffer (canonical CoreMedia path).
    private func makeVideoSampleBuffer(
        from pixelBuffer: CVPixelBuffer, pts: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let fc = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard fc == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = withUnsafePointer(to: &timing) { timingPtr in
            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleTiming: timingPtr,
                sampleBufferOut: &sbuf)
        }
        guard err == noErr else { return nil }
        return sbuf
    }

    // MARK: - Timer / helpers

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

    private func fail(_ message: String) {
        sessionQueue.async { [self] in
            guard phase == .recording else { return }
            stopTimer()
            stopPolling()
            stopPiP()
            teardownWriter(cancel: true)
            endBroadcast()
            phase = .idle
            reader = nil
            publish(.error(message))
        }
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }
}

// MARK: - Broadcast picker + controller delegates

extension ScreenFaceRecorder: RPBroadcastActivityViewControllerDelegate,
                               RPBroadcastControllerDelegate {
    func broadcastActivityViewController(
        _ broadcastActivityViewController: RPBroadcastActivityViewController,
        didFinishWith broadcastController: RPBroadcastController?,
        error: Error?
    ) {
        // RPBroadcastController is not Sendable (Swift 6): box it once so
        // the main-actor hop is explicit and checked.
        final class Box: @unchecked Sendable {
            let controller: RPBroadcastController?
            init(_ c: RPBroadcastController?) { controller = c }
        }
        let box = Box(broadcastController)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            broadcastActivityViewController.dismiss(animated: true) {
                guard let controller = box.controller else {
                    self.publish(.idle)
                    return
                }
                self.startBroadcast(controller: controller)
            }
        }
    }

    func broadcastActivityViewControllerDidCancel(
        _ broadcastActivityViewController: RPBroadcastActivityViewController
    ) {
        DispatchQueue.main.async {
            broadcastActivityViewController.dismiss(animated: true)
            self.publish(.idle)
        }
    }

    func broadcastController(
        _ broadcastController: RPBroadcastController,
        didFinishWithError error: Error?
    ) {
        // Broadcast ended externally (red pill / Control Center).
        DispatchQueue.main.async { [weak self] in
            self?.finishNow()
        }
    }
}

// MARK: - Face camera delegate

extension ScreenFaceRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === faceOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Hop to sessionQueue so `latestFace` and the PiP layer are
        // touched from exactly one queue (same confinement as M1).
        sessionQueue.async { [weak self] in
            self?.handleFaceFrame(pixelBuffer, pts: pts)
        }
    }
}

// MARK: - PiP playback delegate

extension ScreenFaceRecorder: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .invalid, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
