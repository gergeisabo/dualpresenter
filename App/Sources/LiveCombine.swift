import AVFoundation
import CoreGraphics
import CoreVideo
import VideoToolbox

/// Live combine core: draws the front-camera bubble on top of the back-camera
/// frame into one BGRA pixel buffer, in real time during recording.
///
/// Pure CoreVideo/CoreGraphics — no UIKit — so the exact same file compiles
/// on macOS for offline verification (see Tests and the Mac harness).
enum LiveCombine {

    /// Bubble frame in canvas (back-buffer) coordinates, portrait.
    /// Side = 25% of canvas width, centered, near the top.
    static func bubbleRect(canvas: CGSize) -> CGRect {
        let side = canvas.width * 0.25
        let top = canvas.height * 0.05
        return CGRect(
            x: (canvas.width - side) / 2,
            y: top,
            width: side,
            height: side)
    }

    /// Draws `back` full-frame and `front` aspect-fill inside the bubble.
    /// `dest` must be a locked 32BGRA buffer sized like the back buffer.
    /// Both source buffers may be any CVPixelBuffer format VideoToolbox can
    /// convert (native camera output included).
    static func draw(
        back: CVPixelBuffer, front: CVPixelBuffer?, dest: CVPixelBuffer
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

        let bubble = bubbleRect(canvas: canvas.size)
        let path = CGPath(
            roundedRect: bubble,
            cornerWidth: 24, cornerHeight: 24, transform: nil)
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
