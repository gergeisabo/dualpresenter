import AVFoundation
import AVKit
import Combine
import CoreMedia
import os
import Photos
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
    private let audioQueue = DispatchQueue(label: "dualpresenter.sf.audio")
    private let bridgeQueue = DispatchQueue(label: "dualpresenter.sf.bridge")

    private var broadcastController: RPBroadcastController?
    private var faceInput: AVCaptureDeviceInput?
    private let faceOutput = AVCaptureVideoDataOutput()
    private let micOutput = AVCaptureAudioDataOutput()
    private var faceConfigured = false
    private var latestFace: CVPixelBuffer?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var appAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var writerStarted = false
    private var lastVideoPTS: CMTime?
    private var lastAppAudioPTS: CMTime?
    private var lastMicPTS: CMTime?
    private var firstMicPTS: CMTime = .invalid
    private var sessionStartTime: CMTime = .invalid
    private var phase: Phase = .idle
    enum Phase { case idle, armed, recording, finishing }

    private let destPool = LiveCombine.makeBufferPool()

    // Bridge reader is created on sessionQueue but polled on bridgeQueue
    // ONLY (single dedicated queue — no cross-queue access).
    private var reader: FrameBridge.Reader?
    private var pollSource: DispatchSourceTimer?
    private var heartbeatSource: DispatchSourceTimer?

    // PiP facecam
    private var pipController: AVPictureInPictureController?
    private var pipCallVC: FacePipViewController?
    private var pipWindow: UIWindow?
    private var pipHost: UIView?

    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?

    // MARK: - Broadcast picker

    /// Arms the watcher when the user is about to use the system broadcast
    /// picker (RPSystemBroadcastPickerView shown by ScreenFaceScreen). We
    /// can't present the picker ourselves on this OS — load() reports
    /// "service not found" — so we watch for the extension's first frames.
    func requestBroadcast() {
        beginArmWatch()
    }

    private var armWatchSource: DispatchSourceTimer?
    private var armReader: FrameBridge.Reader?
    private var armBaseSeq: UInt64 = 0

    private func beginArmWatch() {
        bridgeQueue.async { [self] in
            guard armWatchSource == nil else { return }
            armReader = try? FrameBridge.Reader()
            // Baseline: if a stale bridge file exists from an earlier
            // session, its seq must not arm us. A fresh broadcast
            // rewrites the file and the seq moves off the baseline.
            armBaseSeq = armReader?.map.magicOK == true
                ? armReader!.map.videoWriteSeq : 0
            let source = DispatchSource.makeTimerSource(queue: bridgeQueue)
            source.schedule(deadline: .now() + 0.5, repeating: .seconds(1))
            source.setEventHandler { [weak self] in
                self?.armWatchTick()
            }
            source.resume()
            armWatchSource = source
        }
    }

    private func armWatchTick() {
        // Re-arm protection: if we are already recording, a new frame
        // burst (broadcast picker re-tapped, extension restart after the
        // orphan guard killed it) must NOT create a second writer.
        if phase == .recording || phase == .finishing {
            return
        }
        if armReader == nil {
            armReader = try? FrameBridge.Reader()
            if armReader == nil { return }
            armBaseSeq = armReader!.map.magicOK
                ? armReader!.map.videoWriteSeq : 0
        }
        guard let live = armReader, live.map.magicOK else { return }
        // Keep the extension's orphan guard fed during the pre-record
        // window (frames flowing, auto-record not yet fired).
        live.stampHeartbeat()
        let seq = live.map.videoWriteSeq
        guard seq > 0, seq != armBaseSeq else { return }
        // Frames flowing — the user tapped Start Broadcast. Hand over.
        armReader = nil
        armWatchSource?.cancel()
        armWatchSource = nil
        reader = live
        sessionQueue.async { [self] in
            configureFaceIfNeeded()
            phase = .armed
            publish(.armed)
            // ONE user action: broadcast live ⇒ recording starts by
            // itself. No second "start recording" step.
            startRecording()
        }
    }

    private func stopArmWatch() {
        bridgeQueue.async { [self] in
            armWatchSource?.cancel()
            armWatchSource = nil
            armReader = nil
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
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                guard let self else { return }
                guard videoOK else {
                    self.publish(.error("Camera access is required."))
                    return
                }
                self.sessionQueue.async { self.configureFace() }
            }
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
        if let mic = AVCaptureDevice.default(for: .audio),
           let micIn = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        micOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(micOutput) {
            session.addOutput(micOutput)
        }
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
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
                appAudioInput = made.appAudio
                micAudioInput = made.micAudio
                adaptor = made.adaptor
                outputURL = made.url
                sessionStartTime = .invalid
                writerStarted = false
                lastVideoPTS = nil
                lastAppAudioPTS = nil
                lastMicPTS = nil
                firstMicPTS = .invalid
                latestFace = nil
                // Writers MUST enter .writing before startSession
                // (crash lesson 160528).
                writer?.startWriting()
                phase = .recording
                publish(.recording)
                startTimer()
                startPolling()
                DispatchQueue.main.async { self.preparePiPAndLeave() }
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
            endBroadcast()
            videoInput?.markAsFinished()
            appAudioInput?.markAsFinished()
            micAudioInput?.markAsFinished()
            writer?.finishWriting {
                self.sessionQueue.async { self.complete() }
            }
        }
    }

    /// Stops the system broadcast without an error sheet.
    private func endBroadcast() {
        reader?.requestStop()
        DispatchQueue.main.async { [self] in
            let owned = broadcastController
            let fresh = RPBroadcastController()
            if let owned, owned.isBroadcasting {
                owned.finishBroadcast { _ in }
            }
            // Picker-started broadcasts never give us a controller; a
            // new RPBroadcastController still talks to the live session.
            if fresh.isBroadcasting {
                fresh.finishBroadcast { _ in }
            } else if owned == nil {
                fresh.finishBroadcast { _ in }
            }
        }
    }

    private func complete() {
        let ok = writer?.status == .completed
        let url = outputURL
        teardownWriter(cancel: false)
        endBroadcast()
        stopArmWatch()
        phase = .idle
        reader = nil
        if ok, let url {
            PhotosSaver.saveVideo(url) { _ in }
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
        // Beat ~4x/sec so the extension's 5s staleness guard never fires
        // while the app is alive (recording or armed-idle).
        let beat = DispatchSource.makeTimerSource(queue: bridgeQueue)
        beat.schedule(deadline: .now(), repeating: .milliseconds(250))
        beat.setEventHandler { [weak self] in
            self?.reader?.stampHeartbeat()
        }
        beat.resume()
        heartbeatSource = beat
    }

    private func stopPolling() {
        pollSource?.cancel()
        pollSource = nil
        heartbeatSource?.cancel()
        heartbeatSource = nil
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
        if !writerStarted {
            sessionStartTime = pts
            writer.startSession(atSourceTime: pts)
            writerStarted = true
        }
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
        if let last = lastVideoPTS, CMTimeCompare(pts, last) <= 0 {
            return
        }
        lastVideoPTS = pts

        guard let pool = destPool else { return }
        var destMaybe: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destMaybe)
        guard let dest = destMaybe else { return }

        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(
            back: frame.pixelBuffer, front: nil,
            placement: bubblePlacement, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        if !adaptor.append(dest, withPresentationTime: pts) {
            let nsErr = writer.error as NSError?
            let code = nsErr?.code ?? 0
            os_log(.error, "DP appendVideo fail: pts=%@ status=%@ err=%@",
                   "\(pts)", "\(writer.status)",
                   "\(nsErr?.localizedDescription ?? "unknown") (\(code))")
            if code == -11847 { return }
            fail("Could not write video [\(nsErr?.localizedDescription ?? "unknown") (\(code))].")
        }
    }

    private func appendAudio(_ chunk: FrameBridge.AudioChunk) {
        guard phase == .recording else { return }
        guard let appAudioInput, appAudioInput.isReadyForMoreMediaData else { return }
        guard writerStarted else { return }
        // Screen frames take a moment to cross the bridge; shift sound
        // later so picture and phone audio line up.
        let pts = chunk.pts + CMTime(seconds: 0.22, preferredTimescale: 600)
        guard CMTimeCompare(pts, sessionStartTime) >= 0 else { return }
        if let last = lastAppAudioPTS, CMTimeCompare(pts, last) < 0 { return }
        lastAppAudioPTS = pts
        guard let sample = makeRawAudioBuffer(chunk, pts: pts) else { return }
        _ = appAudioInput.append(sample)
    }

    private func appendMic(_ sampleBuffer: CMSampleBuffer) {
        guard phase == .recording else { return }
        guard let micAudioInput, micAudioInput.isReadyForMoreMediaData else { return }
        guard writerStarted else { return }
        let srcPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !firstMicPTS.isValid { firstMicPTS = srcPTS }
        let pts = sessionStartTime + (srcPTS - firstMicPTS)
            + CMTime(seconds: 0.22, preferredTimescale: 600)
        if let last = lastMicPTS, CMTimeCompare(pts, last) < 0 { return }
        lastMicPTS = pts
        guard let retagged = retag(sampleBuffer, pts: pts) else { return }
        _ = micAudioInput.append(retagged)
    }

    private func makeRawAudioBuffer(_ chunk: FrameBridge.AudioChunk, pts: CMTime) -> CMSampleBuffer? {
        var asbd = chunk.asbd
        guard asbd.mSampleRate > 0, asbd.mBytesPerFrame > 0 else { return nil }
        let frames = chunk.data.count / Int(asbd.mBytesPerFrame)
        guard frames > 0 else { return nil }
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let bytes = chunk.data.count
        let mem = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        chunk.data.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: bytes)
        var block: CMBlockBuffer?
        let st0 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: bytes,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard st0 == kCMBlockBufferNoErr, let blk = block else {
            mem.deallocate()
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frames),
                             timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let st1 = withUnsafePointer(to: &timing) { timingPtr in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: blk, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format, sampleCount: frames,
                sampleTimingEntryCount: 1, sampleTimingArray: timingPtr,
                sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sbuf)
        }
        guard st1 == noErr else { return nil }
        return sbuf
    }

    private func retag(_ sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0,
                                               arrayToFill: nil, entriesNeededOut: &count)
        var times = Array(repeating: CMSampleTimingInfo(), count: Int(count))
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count,
                                               arrayToFill: &times, entriesNeededOut: &count)
        for i in times.indices {
            let delta = times[i].presentationTimeStamp - times[0].presentationTimeStamp
            times[i].presentationTimeStamp = pts + delta
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count, sampleTimingArray: &times,
            sampleBufferOut: &out)
        return out
    }

    // MARK: - Writer (same shape as M1: H.264 1080x1920 + AAC)

    private func makeWriter() throws -> (writer: AVAssetWriter,
                                         video: AVAssetWriterInput,
                                         appAudio: AVAssetWriterInput,
                                         micAudio: AVAssetWriterInput,
                                         adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                         url: URL) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DP-\(UUID().uuidString)").appendingPathExtension("mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

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

        func aac() -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
            ])
            a.expectsMediaDataInRealTime = true
            return a
        }
        let appAudio = aac()
        let micAudio = aac()
        w.add(appAudio)
        w.add(micAudio)

        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        return (w, video, appAudio, micAudio, ad, url)
    }

    private func teardownWriter(cancel: Bool) {
        if cancel {
            writer?.cancelWriting()
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        writer = nil; videoInput = nil; appAudioInput = nil; micAudioInput = nil; adaptor = nil
        outputURL = nil
        writerStarted = false
        lastVideoPTS = nil
        lastAppAudioPTS = nil
        lastMicPTS = nil
        firstMicPTS = .invalid
        sessionStartTime = .invalid
        latestFace = nil
    }

    // MARK: - PiP facecam (Zoom: float face only AFTER leaving the app)

    private var pipObservers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func preparePiPAndLeave() {
        preparePiP()
        pipController?.startPictureInPicture()
        // Give the first face frames a moment, then go Home so the
        // recording is the user's other apps — not this black screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard self?.phase == .recording else { return }
            UIControl().sendAction(
                #selector(URLSessionTask.suspend),
                to: UIApplication.shared,
                for: nil)
        }
    }
    private func preparePiP() {
        guard pipController == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported()
        else { return }

        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoRecording,
            options: [.mixWithOthers, .defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)

        let callVC = FacePipViewController()
        callVC.preferredContentSize = CGSize(width: 9, height: 16)
        pipCallVC = callVC

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        host.alpha = 0.01
        window.addSubview(host)
        window.isHidden = false
        pipWindow = window
        pipHost = host

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: host,
            contentViewController: callVC)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller

        let nc = NotificationCenter.default
        pipObservers.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.pipOnLeaveApp() })
        pipObservers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.pipOnReturnApp() })
    }

    private func pipOnLeaveApp() {
        guard phase == .recording else { return }
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self, self.bgTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.bgTask)
            self.bgTask = .invalid
        }
        if pipController?.isPictureInPictureActive != true {
            pipController?.startPictureInPicture()
        }
    }

    private func pipOnReturnApp() {
        // Keep the face bubble alive. Stopping PiP here made the camera
        // disappear until the user restarted the whole broadcast.
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func stopPiP() {
        // UIKit + FrontBoard require main-thread for window/layer teardown
        // (crash 2026-08-21-141441: UIWindow._setHidden off-main → SIGTRAP).
        let controller = pipController
        let observers = pipObservers
        pipObservers = []
        pipController = nil
        pipCallVC = nil
        DispatchQueue.main.async { [weak self] in
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            controller?.stopPictureInPicture()
            self?.pipHost?.removeFromSuperview()
            self?.pipHost = nil
            self?.pipWindow?.isHidden = true
            self?.pipWindow = nil
            if let self, self.bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTask)
                self.bgTask = .invalid
            }
        }
    }

    /// Called on videoQueue with the latest face frame: feeds both the
    /// recorder and the PiP display layer.
    private func handleFaceFrame(
        _ pixelBuffer: CVPixelBuffer, pts: CMTime
    ) {
        latestFace = pixelBuffer
        pipCallVC?.enqueue(pixelBuffer, pts: pts)
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

extension ScreenFaceRecorder: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - Face camera delegate

extension ScreenFaceRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                               AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === micOutput {
            sessionQueue.async { [weak self] in
                self?.appendMic(sampleBuffer)
            }
            return
        }
        guard output === faceOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        sessionQueue.async { [weak self] in
            self?.handleFaceFrame(pixelBuffer, pts: pts)
        }
    }
}

/// Zoom-style face bubble for video-call PiP (no play / skip chrome).
final class FacePipViewController: AVPictureInPictureVideoCallViewController {
    private let layer = AVSampleBufferDisplayLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layer.frame = view.bounds
    }

    nonisolated func enqueue(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        var formatDescription: CMVideoFormatDescription?
        let fc = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription)
        guard fc == noErr, let formatDescription else { return }
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
        guard err == noErr, let sbuf else { return }
        layer.enqueue(sbuf)
    }
}
