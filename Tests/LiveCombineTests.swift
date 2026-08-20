import CoreVideo
import XCTest
@testable import DualPresenter

/// Pixel-level tests for LiveCombine: green back frame full-frame, red
/// front frame clipped into the bubble, nil-front tolerated.
final class LiveCombineTests: XCTestCase {

    private let W = 1080, H = 1920

    private func makeBuffer(
        w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8
    ) -> CVPixelBuffer? {
        var buf: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buf) == kCVReturnSuccess, let buffer = buf
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            for col in 0..<w {
                let p = row * bpr + col * 4
                base[p + 0] = b
                base[p + 1] = g
                base[p + 2] = r
                base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func rgb(
        _ buf: CVPixelBuffer, _ x: Int, _ y: Int
    ) -> (Int, Int, Int) {
        let c = LiveCombine.rgba(of: buf, x: x, y: y)!
        return (Int(c.r), Int(c.g), Int(c.b))
    }

    private var bubbleTopDown: CGRect {
        let cg = LiveCombine.bubbleRect(canvas: CGSize(width: W, height: H))
        return CGRect(
            x: cg.minX, y: CGFloat(H) - cg.maxY,
            width: cg.width, height: cg.height)
    }

    func testBackFrameIsDrawnFullScreen() throws {
        let back = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 255, b: 0))
        let dest = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 0, b: 0))
        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(back: back, front: nil, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        let c = rgb(dest, W / 2, H / 2)
        XCTAssertGreaterThan(c.1, 200, "center should be green")
        XCTAssertLessThan(c.0, 50)
    }

    func testFrontBubbleIsDrawnInsideRect() throws {
        let back = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 255, b: 0))
        let front = try XCTUnwrap(makeBuffer(w: 720, h: 1280, r: 255, g: 0, b: 0))
        let dest = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 0, b: 0))
        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(back: back, front: front, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        let bubble = bubbleTopDown
        let inside = rgb(
            dest, Int(bubble.midX), Int(bubble.midY))
        XCTAssertGreaterThan(inside.0, 200, "bubble center should be red")
        XCTAssertLessThan(inside.1, 50)

        let insideEdge = rgb(
            dest, Int(bubble.minX + 30), Int(bubble.midY))
        XCTAssertGreaterThan(insideEdge.0, 200)

        let outside = rgb(
            dest, Int(bubble.minX - 40), Int(bubble.midY))
        XCTAssertGreaterThan(outside.1, 200, "outside bubble should be green")
        XCTAssertLessThan(outside.0, 50)
    }

    func testNilFrontLeavesCanvasUntouched() throws {
        let back = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 255, b: 0))
        let dest = try XCTUnwrap(makeBuffer(w: W, h: H, r: 0, g: 0, b: 0))
        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(back: back, front: nil, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])

        let bubble = bubbleTopDown
        let c = rgb(dest, Int(bubble.midX), Int(bubble.midY))
        XCTAssertGreaterThan(c.1, 200, "bubble area stays back frame")
    }

    func testBubbleRectGeometry() {
        let rect = LiveCombine.bubbleRect(
            canvas: CGSize(width: W, height: H))
        XCTAssertEqual(rect.width, 270, accuracy: 1)
        XCTAssertEqual(rect.height, 270, accuracy: 1)
        // centered horizontally, near the top
        XCTAssertEqual(rect.midX, 540, accuracy: 1)
        XCTAssertLessThan(rect.minY, 200)
    }
}
