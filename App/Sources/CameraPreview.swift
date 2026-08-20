import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Full-frame back-camera preview.
struct BackPreview: UIViewRepresentable {
    let recorder: DualCamRecorder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.setSessionWithNoConnection(recorder.session)
        if let port = recorder.backPreviewPort {
            let connection = AVCaptureConnection(
                inputPort: port, videoPreviewLayer: view.previewLayer)
            if recorder.session.canAddConnection(connection) {
                // Session mutations must be bracketed by begin/commit even
                // while running, or AVFoundation can throw.
                recorder.session.beginConfiguration()
                recorder.session.addConnection(connection)
                recorder.session.commitConfiguration()
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Small front-camera preview used inside the draggable bubble.
struct FrontPreview: UIViewRepresentable {
    let recorder: DualCamRecorder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.setSessionWithNoConnection(recorder.session)
        if let port = recorder.frontPreviewPort {
            let connection = AVCaptureConnection(
                inputPort: port, videoPreviewLayer: view.previewLayer)
            if recorder.session.canAddConnection(connection) {
                recorder.session.beginConfiguration()
                recorder.session.addConnection(connection)
                recorder.session.commitConfiguration()
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Corner placement of the face bubble. Raw values are stable for storage.
enum BubbleCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Snap center (screen coordinates, origin top-left) inside `size`.
    func center(in size: CGSize, side: CGFloat, inset: CGFloat = 16) -> CGPoint {
        let half = side / 2
        switch self {
        case .topLeft:
            return CGPoint(x: inset + half, y: inset + half)
        case .topRight:
            return CGPoint(x: size.width - inset - half, y: inset + half)
        case .bottomLeft:
            return CGPoint(x: inset + half, y: size.height - inset - half)
        case .bottomRight:
            return CGPoint(x: size.width - inset - half,
                           y: size.height - inset - half)
        }
    }
}

/// Draggable face bubble: drag anywhere, snaps to the nearest corner on
/// release. Dragging works mid-recording (RØDE-style) — the recorder is
/// told the new placement live, so the file always matches the screen.
struct FaceBubble: View {
    let recorder: DualCamRecorder
    @Binding var placement: BubblePlacement
    let bubbleSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            FrontPreview(recorder: recorder)
                .frame(width: bubbleSize, height: bubbleSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .position(
                    x: screenX(forCanvasX: placement.centerX, in: size),
                    y: placement.centerY * size.height)
                .onAppear {
                    // Sync the recorded side fraction with the actual
                    // on-screen bubble size.
                    placement = normalized(placement, in: size)
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            placement = clamped(value.location, in: size)
                        }
                        .onEnded { _ in
                            placement = snapped(placement, in: size)
                        }
                )
        }
    }

    // MARK: Screen <-> canvas mapping.
    //
    // The preview aspect-fills the 9:16 canvas, and phone screens are
    // TALLER than 9:16, so the preview shows a horizontal center-crop:
    // the recorded canvas is wider than the screen. Mapping screen
    // points through the crop keeps the recording true to what the
    // user sees (WYSIWYG).

    private var displayedWidth: CGFloat { 9.0 / 16.0 }  // width per point of height

    private func screenX(forCanvasX canvasX: CGFloat, in size: CGSize) -> CGFloat {
        let shown = size.height * displayedWidth
        let crop = max(0, (shown - size.width) / 2)
        return canvasX * shown - crop
    }

    private func canvasX(forScreenX screenX: CGFloat, in size: CGSize) -> CGFloat {
        let shown = size.height * displayedWidth
        let crop = max(0, (shown - size.width) / 2)
        return (screenX + crop) / shown
    }

    // MARK: Placement helpers

    private func normalized(_ p: BubblePlacement, in size: CGSize) -> BubblePlacement {
        BubblePlacement(
            centerX: p.centerX,
            centerY: p.centerY,
            side: bubbleSize / size.width)
    }

    private func clamped(_ center: CGPoint, in size: CGSize) -> BubblePlacement {
        let half = bubbleSize / 2
        let x = min(max(center.x, half), size.width - half)
        let y = min(max(center.y, half + 8), size.height - half)
        return BubblePlacement(
            centerX: canvasX(forScreenX: x, in: size),
            centerY: y / size.height,
            side: bubbleSize / size.width
        ).clampedToCanvas()
    }

    private func snapped(_ p: BubblePlacement, in size: CGSize) -> BubblePlacement {
        let current = CGPoint(
            x: screenX(forCanvasX: p.centerX, in: size),
            y: p.centerY * size.height)
        let corner = BubbleCorner.allCases.min {
            distance($0.center(in: size, side: bubbleSize), current)
                < distance($1.center(in: size, side: bubbleSize), current)
        }
        guard let corner else { return p }
        let c = corner.center(in: size, side: bubbleSize)
        return BubblePlacement(
            centerX: canvasX(forScreenX: c.x, in: size),
            centerY: c.y / size.height,
            side: bubbleSize / size.width
        ).clampedToCanvas()
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        abs(a.x - b.x) + abs(a.y - b.y)
    }
}

// MARK: - Social media framing guides (CapCut-style, preview-only)

/// Vertical platforms with their published safe zones, as fractions of
/// the 1080x1920 canvas: Shorts 110/420/140, Reels 220/430/130,
/// TikTok 130/484/140 (top/bottom/side pixels).
enum SocialPlatform: String, CaseIterable, Identifiable {
    case youtubeShorts
    case instagramReels
    case tiktok

    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtubeShorts: return "Shorts"
        case .instagramReels: return "Reels"
        case .tiktok: return "TikTok"
        }
    }

    var insets: (top: CGFloat, bottom: CGFloat, side: CGFloat) {
        switch self {
        case .youtubeShorts: return (110 / 1920, 420 / 1920, 140 / 1080)
        case .instagramReels: return (220 / 1920, 430 / 1920, 130 / 1080)
        case .tiktok: return (130 / 1920, 484 / 1920, 140 / 1080)
        }
    }
}

/// Dims the areas a platform covers with its UI and outlines the safe
/// area. Purely a preview aid — it is never drawn into the recording.
struct SocialGuidesView: View {
    let platform: SocialPlatform?

    var body: some View {
        GeometryReader { geo in
            if let platform {
                let size = geo.size
                let i = platform.insets
                let top = i.top * size.height
                let bottom = i.bottom * size.height
                let side = i.side * size.width
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.3))
                        .frame(width: size.width, height: top)
                    Rectangle().fill(.black.opacity(0.3))
                        .frame(width: size.width, height: bottom)
                        .offset(y: size.height - bottom)
                    Rectangle().fill(.black.opacity(0.3))
                        .frame(width: side, height: size.height - top - bottom)
                        .offset(y: top)
                    Rectangle().fill(.black.opacity(0.3))
                        .frame(width: side, height: size.height - top - bottom)
                        .offset(x: size.width - side, y: top)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: size.width - 2 * side,
                               height: size.height - top - bottom)
                        .offset(x: side, y: top)
                    Text(platform.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .offset(x: side + 8, y: top + 8)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
