import AVFoundation
import Photos
import SwiftUI
import UIKit

enum PhotosSaver {
    static func saveVideo(_ url: URL, done: @escaping @MainActor (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in done(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, _ in
                Task { @MainActor in done(ok) }
            }
        }
    }
}

/// Post-recording screen for the live-combined recording: the file already
/// contains back camera + face bubble, so this is only save / share / done.
struct FinishScreen: View {
    let video: URL?
    let onDone: () -> Void

    @State private var shareItem: ShareItem?
    @State private var saved = false

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(urls: [item.url])
        }
    }

    @ViewBuilder
    private var content: some View {
        if let video {
            doneView(video)
        } else {
            failedView
        }
    }

    private func doneView(_ url: URL) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(saved ? "Saved to Photos" : "Saving to Photos…")
                .font(.title2.bold())
                .foregroundStyle(.white)
            VideoThumb(url: url)
                .frame(height: 220)
                .cornerRadius(12)
            Button("Share...") { shareItem = ShareItem(url: url) }
                .buttonStyle(FinishButtonStyle())
            Button("Done") { cleanupThenDone(url) }
                .buttonStyle(FinishButtonStyle(secondary: true))
        }
        .padding()
        .onAppear { saveToPhotos(url) }
    }

    private var failedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("Recording failed")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Button("Done") { onDone() }
                .buttonStyle(FinishButtonStyle(secondary: true))
        }
        .padding()
    }

    private func saveToPhotos(_ url: URL) {
        PhotosSaver.saveVideo(url) { ok in
            if ok { saved = true }
        }
    }

    private func cleanupThenDone(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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
