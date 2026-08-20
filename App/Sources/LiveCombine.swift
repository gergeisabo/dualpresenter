import CoreGraphics
import CoreVideo
import VideoToolbox

/// Where the face bubble sits, in normalized CANVAS coordinates
/// (origin top-left, 0...1 of the 1080x1920 frame). Shared by the
/// on-screen preview and the recorder, so the file matches what you
/// see while recording (WYSIWYG), including mid-recording drags.
struct BubblePlacement: Equatable {
    var centerX: CGFloat   // 0...1 of canvas width
    var centerY: CGFloat   // 0...1 of canvas height
    var side: CGFloat      // bubble side as 0...1 of canvas width

    /// Starting placement: bottom-right with the standard 16pt inset.
    static let standard = BubblePlacement(centerX: 0.82, centerY: 0.92, side: 0.28)

    /// Clamped so the whole bubble stays inside the canvas.
    func clampedToCanvas() -> BubblePlacement {
        // Bubble side expressed as a fraction of canvas HEIGHT.
        let hFrac = side * (1080.0 / 1920.0)
        let x = min(max(centerX, side / 2), 1 - side / 2)
        let y = min(max(centerY, hFrac / 2), 1 - hFrac / 2)
        return BubblePlacement(centerX: x, centerY: y, side: side)
    }

    /// Converts to CoreGraphics canvas coordinates (origin BOTTOM-left).
    ///
    /// The pixel buffer is CG-flipped: CG y = 0 maps to the physical
    /// BOTTOM row of the video (verified by the Mac orientation probe).
    /// Screen-style top-down fractions must therefore be inverted.
    func rect(in canvas: CGSize) -> CGRect {
        let s = side * canvas.width
        let cx = centerX * canvas.width
        let cy = (1 - centerY) * canvas.height
        return CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
    }
}

/// Live combine core: draws the front-camera bubble on top of the
/// back-camera frame into one BGRA pixel buffer, in real time during
/// recording.
///
/// Pure CoreVideo/CoreGraphics — no UIKit — so the exact same file
/// compiles on macOS for offline verification (see Tests and the Mac
/// harness).
enum LiveCombine {

    /// Draws `back` full-frame and `front` aspect-fill inside the bubble
    /// at `placement`. `dest` must be a locked 32BGRA buffer sized like
    /// the back buffer. Both source buffers may be any CVPixelBuffer
    /// format VideoToolbox can convert (native camera output included).
    static func draw(
        back: CVPixelBuffer,
        front: CVPixelBuffer?,
        placement: BubblePlacement,
        dest: CVPixelBuffer
    ) {
        let width = CVPixelBufferGetWidth(dest)
        let height = CVPixelBufferGetHeight(dest)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(dest)
        guard let base = CVPixelBufferGetBaseAddress(dest) else { return }

        let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let ctx,
              let backImage = cgImage(from: back) else { return }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(canvas)
        ctx.draw(backImage, in: canvas)

        guard let front, let frontImage = cgImage(from: front) else { return }

        let bubble = placement.rect(in: canvas.size)
        let path = CGPath(
            roundedRect: bubble,
            cornerWidth: min(64, bubble.width * 0.11),
            cornerHeight: min(64, bubble.width * 0.11),
            transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Aspect-fill: scale so both dimensions cover, center, draw.
        let fw = CGFloat(frontImage.width)
        let fh = CGFloat(frontImage.height)
        let scale = max(bubble.width / fw, bubble.height / fh)
        let dw = fw * scale
        let dh = fh * scale
        let drawRect = CGRect(
            x: bubble.midX - dw / 2,
            y: bubble.midY - dh / 2,
            width: dw, height: dh)
        ctx.draw(frontImage, in: drawRect)
        ctx.restoreGState()
    }

    private static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(
            buffer, options: nil, imageOut: &image)
        return image
    }

    /// BGRA pixel-reading helper used by tests (Mac + unit tests).
    /// Memory row 0 is the TOP row of the image (physical, screen-style).
    static func rgba(
        of buffer: CVPixelBuffer, x: Int, y: Int
    ) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard CVPixelBufferGetPixelFormatType(buffer)
                == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.assumingMemoryBound(to: UInt8.self) + y * bpr
        let b = row[x * 4 + 0]
        let g = row[x * 4 + 1]
        let r = row[x * 4 + 2]
        let a = row[x * 4 + 3]
        return (r, g, b, a)
    }

    /// Recyclable pool of 1080x1920 BGRA buffers for combined frames.
    static func makeBufferPool() -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: 1080,
                kCVPixelBufferHeightKey: 1920,
                kCVPixelBufferCGImageCompatibilityKey: true,
            ] as CFDictionary,
            &pool)
        return pool
    }
}
