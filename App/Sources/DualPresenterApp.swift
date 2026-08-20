import SwiftUI

@main
struct DualPresenterApp: App {
    var body: some Scene {
        WindowGroup {
            HomeScreen()
        }
    }
}

/// Two buttons, nothing else. Screen + Face arrives in M2.
struct HomeScreen: View {
    @State private var showDualCam = false

    var body: some View {
        VStack(spacing: 24) {
            Text("DualPresenter")
                .font(.largeTitle.bold())
            Button {
                showDualCam = true
            } label: {
                VStack(spacing: 6) {
                    Label("Dual Cam", systemImage: "arrow.triangle.2.circlepath.camera")
                        .font(.title2.bold())
                    Text("Back camera + your face")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Color.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Label("Screen + Face", systemImage: "iphone.gen3")
                    .font(.title2.bold())
                    .foregroundStyle(.secondary)
                Text("Coming in M2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(24)
        .fullScreenCover(isPresented: $showDualCam) {
            DualCamScreen()
        }
    }
}
