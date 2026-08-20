import XCTest
import CoreVideo
@testable import DualPresenter

final class LiveCombineTests: XCTestCase {

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buf)
        return buf!
    }

    private func fill(
        _ buf: CVPixelBuffer, r: UInt8, g: UInt8, b: UInt8
    ) {
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<CVPixelBufferGetHeight(buf) {
            for x in 0..<CVPixelBufferGetWidth(buf) {
                let o = y * bpr + x * 4
                base[o + 0] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
    }

    private func isRed(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?) -> Bool {
        guard let c else { return false }
        return c.r > 200 && c.g < 80 && c.b < 80
    }

    private func isGreen(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?) -> Bool {
        guard let c else { return false }
        return c.g > 200 && c.r < 80 && c.b < 80
    }

    private func combined(
        placement: BubblePlacement
    ) -> CVPixelBuffer {
        let back = makeBuffer(1080, 1920)
        fill(back, r: 0, g: 255, b: 0)   // green "back camera"
        let front = makeBuffer(720, 1280)
        fill(front, r: 255, g: 0, b: 0)  // red "front camera"
        let dest = makeBuffer(1080, 1920)
        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(
            back: back, front: front, placement: placement, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])
        return dest
    }

    // MARK: Flip fix

    func testBubbleLandsBottomRightInVideo() {
        // Screen-style bottom-right placement (what the user sees).
        let p = BubblePlacement.standard   // (0.82, 0.92)
        let dest = combined(placement: p)

        // Memory row 0 = TOP of the image.
        // Bubble center in the VIDEO: x = 0.82*1080, y = 0.92*1920.
        XCTAssertTrue(isRed(LiveCombine.rgba(of: dest, x: 885, y: 1766)),
                      "bubble center must be bottom-right in the video")
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: 885, y: 153)),
                       "old flipped draw put the bubble at the top")
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: 195, y: 1766)),
                       "old centered draw put the bubble mid-width")
    }

    func testPlacementRectFlipMath() {
        // Canvas-normalized top must become CG BOTTOM (probe: CG y=0 is
        // the physical bottom row). Screen 0.0 (top) -> CG y = height.
        let top = BubblePlacement(centerX: 0.5, centerY: 0.0, side: 0.25)
        let r = top.rect(in: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(r.midY, 1920 - 0 * 1920, accuracy: 1)
        let bottom = BubblePlacement(centerX: 0.5, centerY: 1.0, side: 0.25)
        let r2 = bottom.rect(in: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(r2.midY, 0, accuracy: 1)
    }

    // MARK: Still works: scene full-frame, bubble clipped to its box

    func testSceneAndBubbleBasics() {
        let dest = combined(placement: .standard)
        // Scene fills everything outside the bubble.
        XCTAssertTrue(isGreen(LiveCombine.rgba(of: dest, x: 100, y: 100)))
        XCTAssertTrue(isGreen(LiveCombine.rgba(of: dest, x: 100, y: 1819)))
        XCTAssertTrue(isGreen(LiveCombine.rgba(of: dest, x: 979, y: 100)))
        // Front content stays inside the bubble box (aspect-fill crop).
        let s = 0.28 * 1080   // 302 px side
        let cx = Int(0.82 * 1080), cy = Int(0.92 * 1920)
        XCTAssertTrue(isRed(LiveCombine.rgba(of: dest, x: cx - Int(s / 2) + 8, y: cy)))
        XCTAssertTrue(isRed(LiveCombine.rgba(of: dest, x: cx + Int(s / 2) - 8, y: cy)))
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: cx - Int(s / 2) - 15, y: cy)))
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: cx + Int(s / 2) + 15, y: cy)))
    }

    func testTopPlacementLandsTopInVideo() {
        // A drag to the screen-top must land at the video-top.
        let dest = combined(
            placement: BubblePlacement(centerX: 0.5, centerY: 0.08, side: 0.28))
        XCTAssertTrue(isRed(LiveCombine.rgba(of: dest, x: 540, y: 153)))
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: 540, y: 1766)))
    }

    // MARK: Clamping

    func testClampingKeepsBubbleInsideCanvas() {
        let p = BubblePlacement(centerX: 0.0, centerY: 0.0, side: 0.28)
            .clampedToCanvas()
        let dest = combined(placement: p)
        XCTAssertTrue(isRed(LiveCombine.rgba(of: dest, x: 10, y: 10)),
                      "bubble at canvas top-left corner, fully inside")
        XCTAssertFalse(isRed(LiveCombine.rgba(of: dest, x: 0, y: 0)),
                       "nothing outside the canvas")
    }

    // MARK: No front frame yet

    func testBackOnlyWhenNoFront() {
        let back = makeBuffer(1080, 1920)
        fill(back, r: 0, g: 255, b: 0)
        let dest = makeBuffer(1080, 1920)
        CVPixelBufferLockBaseAddress(dest, [])
        LiveCombine.draw(
            back: back, front: nil, placement: .standard, dest: dest)
        CVPixelBufferUnlockBaseAddress(dest, [])
        XCTAssertTrue(isGreen(LiveCombine.rgba(of: dest, x: 885, y: 1766)))
    }
}
