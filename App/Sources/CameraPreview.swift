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
}

/// Draggable face bubble: drag anywhere, snaps to the nearest corner on
/// release. Dragging works mid-recording (RØDE-style).
struct FaceBubble: View {
    let recorder: DualCamRecorder
    @Binding var corner: BubbleCorner
    let bubbleSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            FrontPreview(recorder: recorder)
                .frame(width: bubbleSize, height: bubbleSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .position(position(in: geo.size, corner: corner))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Live follow while dragging: recompute corner from
                            // the finger position each frame.
                            corner = nearestCorner(
                                to: value.location, in: geo.size)
                        }
                        .onEnded { value in
                            corner = nearestCorner(
                                to: value.location, in: geo.size)
                        }
                )
        }
    }

    private func position(in size: CGSize, corner: BubbleCorner) -> CGPoint {
        let inset: CGFloat = 16
        let half = bubbleSize / 2
        switch corner {
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

    private func nearestCorner(to point: CGPoint, in size: CGSize) -> BubbleCorner {
        let midX = size.width / 2
        let midY = size.height / 2
        switch (point.x < midX, point.y < midY) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
