import AVFoundation
import ReplayKit
import SwiftUI
import UIKit

/// M2 "Screen + Face": pick the broadcast, see your face bubble, record
/// everything on screen with your face on top — one file, live.
struct ScreenFaceScreen: View {
    @StateObject private var recorder = ScreenFaceRecorder()
    @State private var placement: BubblePlacement = .standard
    @State private var showFinish = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch recorder.state {
            case .idle, .picking:
                idleView
            case .armed, .recording:
                armedView
            case .finished:
                Color.black
            case .error(let message):
                errorView(message)
            }

            VStack {
                header
                Spacer()
                if recorder.state == .armed { startControls }
                if recorder.state == .recording { recordingControls }
            }
        }
        .onAppear {
            // Watch for the user starting a broadcast via the system
            // picker at any time while this screen is up.
            recorder.requestBroadcast()
        }
        .onDisappear { recorder.stopRecording() }
        .onChange(of: placement) { _, new in
            recorder.bubblePlacement = new
        }
        .onChange(of: recorder.state) { _, newState in
            if case .finished = newState { showFinish = true }
        }
        .fullScreenCover(isPresented: $showFinish) {
            FinishScreen(
                video: finishVideo,
                onDone: {
                    showFinish = false
                    dismiss()
                }
            )
        }
    }

    // MARK: Views

    private var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.inset.filled.on.rectangle")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.85))
            Text("Screen + Face")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Records everything on your screen with your face in the corner. You can present in any app while recording.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            SystemBroadcastPickerButton(
                extensionID: Bundle.main.bundleIdentifier.map { "\($0).BroadcastUpload" },
                onTap: { recorder.requestBroadcast() }
            )
            .frame(maxWidth: 220)
            .disabled(recorder.state == .picking)
        }
    }

    private var armedView: some View {
        ZStack {
            // Live mirror of what the recording will look like: the face
            // bubble over a placeholder (the screen itself is being
            // captured system-wide).
            ScreenFaceBubble(
                recorder: recorder,
                placement: $placement,
                bubbleSize: 110
            )
            if recorder.state == .armed {
                Text("Broadcast live — place your face bubble, then start.\nThen open any app and present.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Back") { dismiss() }
                .font(.headline)
                .foregroundStyle(.white)
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            Spacer()
            if recorder.state == .recording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(elapsedText(recorder.elapsed))
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 76)
                .background(.black.opacity(0.4), in: Capsule())
            }
        }
        .padding()
    }

    private var startControls: some View {
        VStack(spacing: 10) {
            Button {
                recorder.startRecording()
            } label: {
                HStack {
                    Image(systemName: "record.circle")
                        .font(.system(size: 22, weight: .bold))
                    Text("Record")
                        .font(.headline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 24)
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            Text("Recording the screen + your face.\nPresent in any app — come back here to stop.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button {
                recorder.stopRecording()
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 22, weight: .bold))
                    Text("Stop")
                        .font(.headline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 24)
    }

    private var finishVideo: URL? {
        if case .finished(let url) = recorder.state { return url }
        return nil
    }

    private func elapsedText(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Apple's own broadcast-start button (RPSystemBroadcastPickerView). On
/// iOS 18 this is the supported trigger — it lists registered broadcast
/// extensions; if ours isn't listed, iOS refuses to preselect it.
struct SystemBroadcastPickerButton: View {
    let extensionID: String?
    var onTap: () -> Void = {}
    @State private var proxy = PickerProxy()

    var body: some View {
        ZStack {
            // Apple's real button, hidden from view but alive so we can
            // programmatically press it.
            Represented(extensionID: extensionID, proxy: proxy)
                .frame(width: 1, height: 1)
                .opacity(0.001)
            Button {
                onTap()
                // Press Apple's hidden button → iOS shows the real sheet.
                proxy.press()
            } label: {
                Label("Choose Screen Recording", systemImage: "broadcast")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
    }

    /// Holds a weak reference to Apple's real button so the big styled
    /// button can programmatically press it.
    @MainActor
    final class PickerProxy {
        weak var button: RPSystemBroadcastPickerView?
        func press() {
            guard let button else { return }
            for case let sub as UIButton in button.subviews {
                sub.sendActions(for: .touchUpInside)
            }
        }
    }

    struct Represented: UIViewRepresentable {
        let extensionID: String?
        var proxy: PickerProxy

        func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
            let picker = RPSystemBroadcastPickerView()
            picker.preferredExtension = extensionID
            picker.showsMicrophoneButton = true
            proxy.button = picker
            return picker
        }

        func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
    }
}

/// Face bubble that works with the M2 recorder's front-camera session.
/// (The M1 FaceBubble takes a DualCamRecorder; this is the same drag /
/// corner-snap behavior for the screen mode.)
struct ScreenFaceBubble: View {
    let recorder: ScreenFaceRecorder
    @Binding var placement: BubblePlacement
    let bubbleSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            FrontFacePreview(recorder: recorder)
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
                    placement = BubblePlacement(
                        centerX: placement.centerX,
                        centerY: placement.centerY,
                        side: bubbleSize / size.width)
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            placement = clampAndConvert(
                                value.location, in: size)
                        }
                        .onEnded { _ in
                            placement = snapToCorner(placement, in: size)
                        }
                )
        }
    }

    private var displayedWidth: CGFloat { 9.0 / 16.0 }

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

    private func clampAndConvert(
        _ center: CGPoint, in size: CGSize
    ) -> BubblePlacement {
        let half = bubbleSize / 2
        let x = min(max(center.x, half), size.width - half)
        let y = min(max(center.y, half + 8), size.height - half)
        return BubblePlacement(
            centerX: canvasX(forScreenX: x, in: size),
            centerY: y / size.height,
            side: bubbleSize / size.width
        ).clampedToCanvas()
    }

    private func snapToCorner(
        _ p: BubblePlacement, in size: CGSize
    ) -> BubblePlacement {
        let current = CGPoint(
            x: screenX(forCanvasX: p.centerX, in: size),
            y: p.centerY * size.height)
        let corner = BubbleCorner.allCases.min {
            manhattan($0.center(in: size, side: bubbleSize), current)
                < manhattan($1.center(in: size, side: bubbleSize), current)
        }
        guard let corner else { return p }
        let c = corner.center(in: size, side: bubbleSize)
        return BubblePlacement(
            centerX: canvasX(forScreenX: c.x, in: size),
            centerY: c.y / size.height,
            side: bubbleSize / size.width
        ).clampedToCanvas()
    }

    private func manhattan(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        abs(a.x - b.x) + abs(a.y - b.y)
    }
}

/// Front-camera preview layer bound to the M2 session.
struct FrontFacePreview: UIViewRepresentable {
    let recorder: ScreenFaceRecorder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.setSessionWithNoConnection(recorder.session)
        if let port = recorder.facePreviewPort {
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
