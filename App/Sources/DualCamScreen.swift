import SwiftUI

/// Dual Cam recording screen: full-frame back preview, draggable face
/// bubble (the recording matches its position — WYSIWYG), CapCut-style
/// social safe-zone guides, one Record/Stop button, elapsed readout.
struct DualCamScreen: View {
    @StateObject private var recorder = DualCamRecorder()
    @State private var placement: BubblePlacement = .standard
    @State private var guide: SocialPlatform?
    @State private var showFinish = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if recorder.ready {
                BackPreview(recorder: recorder)
                    .ignoresSafeArea()
                SocialGuidesView(platform: guide)
                    .ignoresSafeArea()
                FaceBubble(
                    recorder: recorder,
                    placement: $placement,
                    bubbleSize: 110
                )
            } else {
                ProgressView("Setting up cameras…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            VStack {
                header
                if recorder.state != .recording {
                    guidePicker
                }
                Spacer()
                controls
            }
        }
        .onAppear { recorder.setUp() }
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
                elapsedLabel
            }
        }
        .padding()
    }

    private var elapsedLabel: some View {
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

    /// CapCut-style platform guide switcher (preview-only aid).
    private var guidePicker: some View {
        HStack(spacing: 8) {
            guideChip("Off", platform: nil)
            ForEach(SocialPlatform.allCases) { platform in
                guideChip(platform.label, platform: platform)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func guideChip(_ label: String, platform: SocialPlatform?) -> some View {
        Button {
            guide = platform
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(guide == platform ? .black : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    guide == platform ? Color.white : Color.black.opacity(0.4),
                    in: Capsule()
                )
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if case .error(let message) = recorder.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.red.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            }
            Button {
                if recorder.state == .recording {
                    recorder.stopRecording()
                } else if recorder.state == .idle {
                    recorder.startRecording()
                }
            } label: {
                HStack {
                    Image(systemName: recorder.state == .recording ? "stop.fill" : "record.circle")
                        .font(.system(size: 22, weight: .bold))
                    Text(recorder.state == .recording ? "Stop" : "Record")
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
