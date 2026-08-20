import AVFoundation
import Photos
import SwiftUI
import UIKit

/// Post-recording flow: glue the two videos into one (Compositor), then let
/// the user save to Photos or share. Cleans up temp files when done.
struct FinishScreen: View {
    let front: URL?
    let back: URL?
    let onDone: () -> Void

    @State private var phase: Phase = .merging
    @State private var progress: Double = 0
    @State private var resultURL: URL?
    @State private var errorMessage: String?
    @State private var shareItem: ShareItem?

    enum Phase: Equatable {
        case merging, done, failed
    }

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .onAppear { merge() }
        .sheet(item: $shareItem) { item in
            ShareSheet(urls: [item.url])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .merging: mergingView
        case .done: doneView
        case .failed: failedView
        }
    }
    private var mergingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .tint(.white)
                .frame(maxWidth: 280)
            Text("Gluing your videos...")
                .foregroundStyle(.white)
            Text("\(Int(progress * 100))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.gray)
        }
    }

    private var doneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Your video is ready")
                .font(.title2.bold())
                .foregroundStyle(.white)
            if let url = resultURL {
                VideoThumb(url: url)
                    .frame(height: 180)
                    .cornerRadius(12)
            }
            Button("Save to Photos") { saveToPhotos() }
                .buttonStyle(FinishButtonStyle())
            Button("Share...") { shareItem = resultURL.map { ShareItem(url: $0) } }
                .buttonStyle(FinishButtonStyle())
            Button("Done") { cleanupThenDone() }
                .buttonStyle(FinishButtonStyle(secondary: true))
        }
        .padding()
    }

    private var failedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("Merging failed")
                .font(.title2.bold())
                .foregroundStyle(.white)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { onDone() }
                .buttonStyle(FinishButtonStyle(secondary: true))
        }
        .padding()
    }
    private func merge() {
        guard let front, let back else {
            phase = .failed
            errorMessage = "The raw recordings are missing."
            return
        }
        Task {
            do {
                let url = try await Compositor.composite(
                    back: back, front: front, corner: .bottomRight
                ) { value in
                    Task { @MainActor in progress = value }
                }
                try? FileManager.default.removeItem(at: front)
                try? FileManager.default.removeItem(at: back)
                await MainActor.run {
                    resultURL = url
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .failed
                }
            }
        }
    }

    private func saveToPhotos() {
        guard let url = resultURL else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, _ in }
        }
    }

    private func cleanupThenDone() {
        if let url = resultURL {
            try? FileManager.default.removeItem(at: url)
        }
        onDone()
    }
}
// MARK: - Small helpers

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController, context: Context) {}
}

struct VideoThumb: View {
    let url: URL
    @State private var thumb: UIImage?

    var body: some View {
        Group {
            if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .onAppear { generateThumb() }
    }

    private func generateThumb() {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 600, height: 600)
        generator.appliesPreferredTrackTransform = true
        Task {
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                let image = UIImage(cgImage: cgImage)
                await MainActor.run { thumb = image }
            } catch {
                // placeholder stays
            }
        }
    }
}

struct FinishButtonStyle: ButtonStyle {
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                secondary ? Color.white.opacity(0.12) : Color.white.opacity(0.2),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
