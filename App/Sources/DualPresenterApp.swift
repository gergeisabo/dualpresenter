import SwiftUI

@main
struct DualPresenterApp: App {
    var body: some Scene {
        WindowGroup {
            HomeScreen()
        }
    }
}

/// Two buttons, nothing else.
struct HomeScreen: View {
    @State private var showDualCam = false
    @State private var showScreenFace = false

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

            Button {
                showScreenFace = true
            } label: {
                VStack(spacing: 6) {
                    Label("Screen + Face", systemImage: "iphone.gen3")
                        .font(.title2.bold())
                    Text("Any app + your face")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(Color.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .fullScreenCover(isPresented: $showDualCam) {
            DualCamScreen()
        }
        .fullScreenCover(isPresented: $showScreenFace) {
            ScreenFaceScreen()
        }
    }
}
