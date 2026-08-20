import Testing
import CoreGraphics
@testable import DualPresenter

struct CompositorTests {
    // 1920×1080 back, 1280×720 front — the app's flagship case (back 1080p, front 720p).
    private let back = CGSize(width: 1920, height: 1080)
    private let front = CGSize(width: 1280, height: 720)

    private func near(_ a: CGFloat, _ b: CGFloat, eps: CGFloat = 0.001) -> Bool {
        abs(a - b) < eps
    }

    // MARK: PiP width = 25% of back width

    @Test func pipWidthIsQuarterOfBackWidth() {
        let r = PiPLayout.pipRect(back: back, front: front)
        #expect(r.width == back.width * 0.25)
        #expect(r.width == 480)
    }

    // MARK: Aspect-fill preserves the front aspect

    @Test func pipRectPreservesFrontAspect() {
        let r = PiPLayout.pipRect(back: back, front: front)
        #expect(near(r.height / r.width, front.height / front.width))
    }

    @Test func pipRectPreservesFrontAspectSquareFront() {
        // Square front into a wide PiP: width is the binding dimension.
        let squareFront = CGSize(width: 720, height: 720)
        let r = PiPLayout.pipRect(back: back, front: squareFront)
        #expect(r.width == 480)
        #expect(r.height == 480) // square stays square
    }

    @Test func pipRectPreservesFrontAspectTallFront() {
        // Tall (portrait) front: height grows past the rect width — still proportional.
        let tallFront = CGSize(width: 720, height: 1280)
        let r = PiPLayout.pipRect(back: back, front: tallFront)
        #expect(near(r.height / r.width, 1280.0 / 720.0))
        #expect(r.height > r.width)
    }

    // MARK: Corners

    @Test func bottomRightDefaultCorner() {
        let explicit = PiPLayout.pipRect(back: back, front: front, corner: .bottomRight)
        let omitted = PiPLayout.pipRect(back: back, front: front)
        #expect(explicit == omitted)
    }

    @Test func allFourCornersPlaceRectInsideOutput() {
        let m: CGFloat = back.width * 0.025
        for corner in [Corner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let r = PiPLayout.pipRect(back: back, front: front, corner: corner)
            #expect(r.minX >= 0 && r.maxX <= back.width)
            #expect(r.minY >= 0 && r.maxY <= back.height)
            // Margin on its corner's two edges, exact width everywhere.
            #expect(r.width == 480)
            switch corner {
            case .topLeft:
                #expect(r.minX == m && r.maxY == back.height - m)
            case .topRight:
                #expect(r.maxX == back.width - m && r.maxY == back.height - m)
            case .bottomLeft:
                #expect(r.minX == m && r.minY == m)
            case .bottomRight:
                #expect(r.maxX == back.width - m && r.minY == m)
            }
        }
    }

    // MARK: Output size override

    @Test func outputSizeOverrideRescales() {
        // Output override rescales placement (pip stays 25% of BACK width per spec).
        let out = CGSize(width: 1280, height: 720)
        let r = PiPLayout.pipRect(back: back, front: front, output: out)
        #expect(r.width == 480) // still quarter of back width
        #expect(r.maxX <= out.width && r.maxY <= out.height)
    }

    // MARK: Aspect-fill transform

    @Test func aspectFillCoversRectWithoutDistortion() {
        let r = PiPLayout.pipRect(back: back, front: front)
        let t = PiPLayout.aspectFillTransform(videoSize: front, into: r)
        // Same aspect front into rect: exact fit — no distortion, no crop.
        #expect(near(t.a, r.width / front.width))
        #expect(near(t.d, r.height / front.height))
        #expect(near(t.a, t.d))
        // Corners land on the rect.
        let origin = CGPoint(x: 0, y: 0).applying(t)
        #expect(near(origin.x, r.minX))
        #expect(near(origin.y, r.minY))
        let far = CGPoint(x: front.width, y: front.height).applying(t)
        #expect(near(far.x, r.maxX))
        #expect(near(far.y, r.maxY))
    }

    @Test func aspectFillTallVideoCropsOverflow() {
        // Tall video (720×1280) into a wide rect (480×270): width binds the uniform
        // scale, vertical overflow is cropped — centered, no distortion.
        let rect = CGRect(x: 100, y: 100, width: 480, height: 270)
        let tall = CGSize(width: 720, height: 1280)
        let t = PiPLayout.aspectFillTransform(videoSize: tall, into: rect)
        #expect(near(t.a, rect.width / tall.width))  // width binds
        #expect(near(t.a, t.d))                      // uniform scale: no distortion
        #expect(near(t.tx, rect.minX))               // width fits exactly
        let scaledH = tall.height * t.d
        #expect(scaledH > rect.height)               // vertical overflow ...
        #expect(near(rect.midY - scaledH / 2, t.ty)) // ... centered, so crop is even
    }
}
