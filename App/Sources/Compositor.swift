import Foundation
import CoreGraphics

// MARK: - Pure layout core (no AVFoundation — unit-testable)

enum Corner {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct PiPLayout {
    /// Compute the picture-in-picture rect for the front video.
    /// - Width: 25% of the back video width.
    /// - Aspect-fill: the front video's aspect is preserved; it is cropped
    ///   (never stretched) when it doesn't match the rect.
    /// - Placed in the corner with a 2.5%-of-back-width margin.
    /// Coordinates are output-space, origin bottom-left (Core Animation).
    static func pipRect(back: CGSize, front: CGSize, output: CGSize? = nil,
                        corner: Corner = .bottomRight) -> CGRect {
        precondition(back.width > 0 && back.height > 0, "back size must be positive")
        precondition(front.width > 0 && front.height > 0, "front size must be positive")
        let out = output ?? back
        precondition(out.width > 0 && out.height > 0, "output size must be positive")

        let pipWidth = back.width * 0.25
        let pipHeight = pipWidth * front.height / front.width  // preserve front aspect
        let margin = back.width * 0.025

        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:     x = margin;                            y = out.height - margin - pipHeight
        case .topRight:    x = out.width - margin - pipWidth;     y = out.height - margin - pipHeight
        case .bottomLeft:  x = margin;                            y = margin
        case .bottomRight: x = out.width - margin - pipWidth;     y = margin
        }
        return CGRect(x: x, y: y, width: pipWidth, height: pipHeight)
    }

    /// Aspect-FILL: uniform scale so `videoSize` covers `rect`, centered; overflow is cropped.
    static func aspectFillTransform(videoSize: CGSize, into rect: CGRect) -> CGAffineTransform {
        precondition(videoSize.width > 0 && videoSize.height > 0, "video size must be positive")
        let scale = max(rect.width / videoSize.width, rect.height / videoSize.height)
        let scaledW = videoSize.width * scale
        let scaledH = videoSize.height * scale
        let tx = rect.midX - scaledW / 2
        let ty = rect.midY - scaledH / 2
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }

    /// Aspect-FIT: uniform scale so `videoSize` fits inside `size`, centered (letterboxed).
    static func aspectFitTransform(videoSize: CGSize, into size: CGSize) -> CGAffineTransform {
        precondition(videoSize.width > 0 && videoSize.height > 0, "video size must be positive")
        let scale = min(size.width / videoSize.width, size.height / videoSize.height)
        let scaledW = videoSize.width * scale
        let scaledH = videoSize.height * scale
        let tx = (size.width - scaledW) / 2
        let ty = (size.height - scaledH) / 2
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }
}

// MARK: - Export wrapper (AVFoundation offline composite)

import AVFoundation

enum Compositor {
    static func composite(back: URL, front: URL, corner: Corner = .bottomRight,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let backAsset = AVURLAsset(url: back)
        let frontAsset = AVURLAsset(url: front)
        guard let backVideo = try await backAsset.loadTracks(withMediaType: .video).first,
              let frontVideo = try await frontAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Compositor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing video track"])
        }

        let composition = AVMutableComposition()
        guard let backCompVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
              let frontCompVideo = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Compositor", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not add composition tracks"])
        }

        let backDuration = try await backAsset.load(.duration)
        let frontDuration = try await frontAsset.load(.duration)
        try backCompVideo.insertTimeRange(
            CMTimeRange(start: CMTime.zero, duration: backDuration),
            of: backVideo, at: CMTime.zero)
        try frontCompVideo.insertTimeRange(
            CMTimeRange(start: CMTime.zero, duration: CMTimeMinimum(backDuration, frontDuration)),
            of: frontVideo, at: CMTime.zero)

        // Audio from the back asset only (single source of truth).
        if let backAudio = try await backAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAudio.insertTimeRange(
                CMTimeRange(start: CMTime.zero, duration: backDuration),
                of: backAudio, at: CMTime.zero)
        }

        // Display sizes (natural size run through the preferred transform).
        func displaySize(of track: AVAssetTrack) async throws -> CGSize {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let s = natural.applying(transform)
            return CGSize(width: abs(s.width), height: abs(s.height))
        }
        let backSize = try await displaySize(of: backVideo)
        let frontSize = try await displaySize(of: frontVideo)
        let renderSize = backSize
        let pip = PiPLayout.pipRect(back: backSize, front: frontSize,
                                    output: renderSize, corner: corner)
        // Composition transforms use a TOP-LEFT origin (positive Y moves down);
        // PiPLayout speaks bottom-left (Core Graphics) — flip the rect.
        let pipTopLeft = CGRect(x: pip.minX, y: renderSize.height - pip.maxY,
                                width: pip.width, height: pip.height)

        // Back full-frame, rendered first (bottom layer). Centered aspect-fit —
        // symmetric, so the same transform is valid in either coordinate origin.
        let backLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: backCompVideo)
        backLayer.setTransform(
            PiPLayout.aspectFitTransform(videoSize: backSize, into: renderSize),
            at: CMTime.zero)
        // Front scaled/positioned into the PiP rect, on top.
        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontCompVideo)
        frontLayer.setTransform(
            PiPLayout.aspectFillTransform(videoSize: frontSize, into: pipTopLeft),
            at: CMTime.zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: CMTime.zero, duration: backDuration)
        instruction.layerInstructions = [backLayer, frontLayer]  // back first, front on top

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Compositor", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "export session creation failed"])
        }
        export.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        export.outputURL = outputURL
        export.outputFileType = .mp4

        // Progress via polling (ponytail: simpler than KVO).
        final class PollBox: @unchecked Sendable {
            let session: AVAssetExportSession
            init(session: AVAssetExportSession) { self.session = session }
        }
        var pollTask: Task<Void, Never>?
        if let progress {
            let box = PollBox(session: export)
            pollTask = Task {
                var last = -1.0
                while box.session.status == .waiting || box.session.status == .exporting {
                    let p = Double(box.session.progress)
                    if p != last { last = p; progress(p) }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        defer { pollTask?.cancel() }

        await export.export()
        if export.status == .failed {
            throw export.error ?? NSError(domain: "Compositor", code: 4,
                                          userInfo: [NSLocalizedDescriptionKey: "export failed"])
        }
        progress?(1.0)
        return outputURL
    }
}
