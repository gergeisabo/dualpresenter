import Foundation
import CoreGraphics
import CoreMedia
import CoreAudio
import CoreVideo
import VideoToolbox
import Darwin

/// Cross-process frame bridge: the Broadcast Upload Extension (writer)
/// stores screen frames + mic audio into an mmap'd ring file inside the
/// App Group container; the main app (reader) polls it live and composites
/// while recording. Single writer, single reader, flock-protected.
///
/// Layout (little-endian, fixed offsets):
///   0    magic, version
///   8    videoWriteSeq (next seq to write)
///   16   audioWriteSeq
///   24   command (1 started, 2 stopRequested, 3 ended)
///   32   reserved
///   40   video meta[3]  {seq, pts(value,timescale,flags), bpr, w, h}
///   184  audio meta[24] {seq, pts, byteCount, numSamples, asbd[64]}
///   4096 video slots: 3 x 1080*1920*4 BGRA
///   then audio slots: 24 x 8192 bytes
enum FrameBridge {

    static let appGroupID = "group.com.gergeisabo.dualpresenter"
    static let fileName = "framebridge.bin"

    static let videoSlotCount = 3
    static let videoSlotBytes = 1080 * 1920 * 4
    static let audioSlotCount = 24
    static let audioSlotBytes = 8192

    static let headerBytes = 4096
    static var videoDataOffset: Int { headerBytes }
    static var audioDataOffset: Int {
        videoDataOffset + videoSlotCount * videoSlotBytes
    }
    static var fileBytes: Int {
        audioDataOffset + audioSlotCount * audioSlotBytes
    }

    static let magic: UInt32 = 0x44504642   // "DPFB"

    enum Command: UInt32 {
        case none = 0
        case started = 1
        case stopRequested = 2
        case ended = 3
    }

    struct PTS {
        var value: Int64
        var timescale: Int32
        var flags: UInt32

        init(time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
        }

        var cmTime: CMTime {
            CMTime(value: value, timescale: timescale,
                   flags: CMTimeFlags(rawValue: flags), epoch: 0)
        }

        var isValid: Bool {
            flags & CMTimeFlags.valid.rawValue != 0
        }
        var rawSeconds: Double {
            isValid && timescale > 0
                ? Double(value) / Double(timescale) : 0
        }
    }

    // MARK: - File mapping

    /// Maps the bridge file. Writer creates/truncates it; reader maps
    /// the existing file. Returns the base pointer and the fd (kept open
    /// for flock).
    final class Mapping {
        let fd: Int32
        let base: UnsafeMutableRawPointer
        let length: Int

        init(asWriter: Bool) throws {
            // DP_BRIDGE_DIR: test-only override of the App Group container
            // (absent on iOS in production).
            let dirURL: URL
            if let testDir = ProcessInfo.processInfo
                .environment["DP_BRIDGE_DIR"] {
                dirURL = URL(fileURLWithPath: testDir)
            } else if
                let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: appGroupID) {
                dirURL = container
            } else {
                throw NSError(domain: "FrameBridge", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "App Group \(appGroupID) unavailable"])
            }
            let url = dirURL.appendingPathComponent(fileName)
            let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else {
                throw NSError(domain: "FrameBridge", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "open failed: \(String(cString: strerror(errno)))"])
            }
            self.fd = fd
            if asWriter {
                ftruncate(fd, off_t(fileBytes))
            }
            var st = stat()
            stat(url.path, &st)
            guard st.st_size >= fileBytes else {
                close(fd)
                throw NSError(domain: "FrameBridge", code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "bridge file too small (\(st.st_size))"])
            }
            guard let base = mmap(nil, fileBytes, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, 0),
                  base != MAP_FAILED
            else {
                close(fd)
                throw NSError(domain: "FrameBridge", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "mmap failed"])
            }
            self.base = base
            self.length = fileBytes
            if asWriter {
                memset(base, 0, headerBytes)
                base.advanced(by: 0).storeBytes(of: magic, as: UInt32.self)
                base.advanced(by: 4).storeBytes(of: UInt32(1), as: UInt32.self)
            }
        }

        deinit {
            munmap(base, length)
            close(fd)
        }

        // Header accessors
        var magicOK: Bool {
            base.advanced(by: 0).load(as: UInt32.self) == FrameBridge.magic
        }
        var videoWriteSeq: UInt64 {
            base.advanced(by: 8).load(as: UInt64.self)
        }
        var audioWriteSeq: UInt64 {
            base.advanced(by: 16).load(as: UInt64.self)
        }
        var command: Command {
            Command(rawValue: base.advanced(by: 24).load(as: UInt32.self)) ?? .none
        }

        func lock(exclusive: Bool) {
            flock(fd, exclusive ? LOCK_EX : LOCK_SH)
        }

        func unlock() {
            flock(fd, LOCK_UN)
        }
    }

    // MARK: - Writer (extension side)

    final class Writer {
        let map: Mapping

        init() throws {
            map = try Mapping(asWriter: true)
        }

        /// Draws the incoming screen frame (any CVPixelBuffer) aspect-fit
        /// into the next 1080x1920 BGRA slot. Returns the slot index to
        /// pass to `commitVideoFrame`, or nil if drawing failed.
        func beginVideoFrame(from buffer: CVPixelBuffer) -> Int? {
            let index = Int(map.videoWriteSeq % UInt64(videoSlotCount))
            let slotPtr = map.base + videoDataOffset + index * videoSlotBytes
            guard let ctx = CGContext(
                data: slotPtr,
                width: 1080, height: 1920,
                bitsPerComponent: 8,
                bytesPerRow: 1080 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }

            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard let image else { return nil }

            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 1920))
            // Aspect-fit (contain): whole screen visible, black side bars.
            let scale = min(1080.0 / CGFloat(image.width),
                            1920.0 / CGFloat(image.height))
            let w = CGFloat(image.width) * scale
            let h = CGFloat(image.height) * scale
            ctx.draw(image, in: CGRect(
                x: (1080 - w) / 2, y: (1920 - h) / 2, width: w, height: h))
            return index
        }

        /// Un-read frames pending for the app (0 = app is keeping up).
        /// Reads the app's consumed-mark published in the header.
        func videoBacklog() -> Int {
            let writeSeq = map.videoWriteSeq
            let readMark = map.base.advanced(by: 32).load(as: UInt64.self)
            return max(0, Int(writeSeq - readMark))
        }

        /// Publishes the slot. Caller must hold no lock; it is taken here.
        func commitVideoFrame(slot: Int, pts: CMTime) {
            map.lock(exclusive: true)
            let seq = map.videoWriteSeq
            let metaOffset = 40 + slot * 48
            map.base.advanced(by: metaOffset).storeBytes(of: seq, as: UInt64.self)
            let p = PTS(time: pts)
            map.base.advanced(by: metaOffset + 8).storeBytes(of: p, as: PTS.self)
            map.base.advanced(by: metaOffset + 32).storeBytes(of: UInt32(1080 * 4), as: UInt32.self)
            map.base.advanced(by: metaOffset + 36).storeBytes(of: UInt32(1080), as: UInt32.self)
            map.base.advanced(by: metaOffset + 40).storeBytes(of: UInt32(1920), as: UInt32.self)
            map.base.advanced(by: 8).storeBytes(of: seq + 1, as: UInt64.self)
            map.unlock()
        }

        /// Stores one audio chunk (interleaved Int16 PCM + format facts).
        func storeAudio(
            bytes: UnsafeRawPointer, byteCount: Int,
            sampleRate: Double, numChannels: Int,
            pts: CMTime
        ) {
            let n = min(byteCount, audioSlotBytes)
            map.lock(exclusive: true)
            let slot = Int(map.audioWriteSeq % UInt64(audioSlotCount))
            let dataPtr = map.base + audioDataOffset + slot * audioSlotBytes
            memcpy(dataPtr, bytes, n)
            let metaOffset = 184 + slot * 104
            map.base.advanced(by: metaOffset).storeBytes(of: map.audioWriteSeq, as: UInt64.self)
            let p = PTS(time: pts)
            map.base.advanced(by: metaOffset + 8).storeBytes(of: p, as: PTS.self)
            map.base.advanced(by: metaOffset + 32).storeBytes(of: UInt32(n), as: UInt32.self)
            map.base.advanced(by: metaOffset + 44).storeBytes(
                of: sampleRate, as: Double.self)
            map.base.advanced(by: metaOffset + 52).storeBytes(
                of: UInt32(max(1, numChannels)), as: UInt32.self)
            map.base.advanced(by: 16).storeBytes(of: map.audioWriteSeq + 1, as: UInt64.self)
            map.unlock()
        }

        func setCommand(_ command: Command) {
            map.lock(exclusive: true)
            map.base.advanced(by: 24).storeBytes(of: command.rawValue, as: UInt32.self)
            map.unlock()
        }
    }

    // MARK: - Reader (app side)

    struct VideoFrame: @unchecked Sendable {
        let seq: UInt64
        let pts: CMTime
        let pixelBuffer: CVPixelBuffer   // private copy, safe to keep
    }

    struct AudioChunk {
        let seq: UInt64
        let pts: CMTime
        let data: Data              // interleaved Int16 PCM
        let sampleRate: Double
        let channels: Int
        /// Frames (samples per channel) in `data`.
        var frameCount: Int {
            channels > 0 ? data.count / (channels * 2) : 0
        }
    }

    final class Reader {
        let map: Mapping
        private var lastVideoSeq: UInt64 = 0
        private var lastAudioSeq: UInt64 = 0

        init() throws {
            map = try Mapping(asWriter: false)
        }

        /// Returns the newest un-read video frame, or nil. Skips older
        /// frames (keeps latency low).
        func pollVideo() -> VideoFrame? {
            map.lock(exclusive: false)
            defer { map.unlock() }
            let writeSeq = map.videoWriteSeq
            guard writeSeq > lastVideoSeq, writeSeq > 0 else { return nil }
            let newest = writeSeq - 1
            let slot = Int(newest % UInt64(videoSlotCount))
            let metaOffset = 40 + slot * 48
            let slotSeq = map.base.advanced(by: metaOffset).load(as: UInt64.self)
            guard slotSeq == newest else { return nil }   // torn write: skip
            let pts = map.base.advanced(by: metaOffset + 8).load(as: PTS.self)
            // +1: consuming `newest` means the next poll must wait for a
            // NEW write (else the same frame re-qualifies forever).
            lastVideoSeq = newest + 1
            // Publish the consumed-mark so the extension can pace itself
            // (videoBacklog). Offset 32 is dedicated to this.
            map.base.advanced(by: 32).storeBytes(
                of: lastVideoSeq, as: UInt64.self)

            // Copy the slot into our own pixel buffer.
            var buf: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1080, 1920,
                                kCVPixelFormatType_32BGRA, nil, &buf)
            guard let buf else { return nil }
            CVPixelBufferLockBaseAddress(buf, [])
            if let dst = CVPixelBufferGetBaseAddress(buf) {
                let src = map.base + videoDataOffset + slot * videoSlotBytes
                memcpy(dst, src, videoSlotBytes)
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            return VideoFrame(
                seq: newest, pts: pts.cmTime, pixelBuffer: buf)
        }

        /// Returns all un-read audio chunks, oldest first.
        func pollAudio() -> [AudioChunk] {
            map.lock(exclusive: false)
            defer { map.unlock() }
            var chunks: [AudioChunk] = []
            let writeSeq = map.audioWriteSeq
            while lastAudioSeq < writeSeq {
                let seq = lastAudioSeq
                let slot = Int(seq % UInt64(audioSlotCount))
                let metaOffset = 184 + slot * 104
                let slotSeq = map.base.advanced(by: metaOffset).load(as: UInt64.self)
                guard slotSeq == seq else {
                    lastAudioSeq += 1   // torn/overwritten: skip
                    continue
                }
                let pts = map.base.advanced(by: metaOffset + 8).load(as: PTS.self)
                let byteCount = Int(map.base.advanced(by: metaOffset + 32)
                    .load(as: UInt32.self))
                let sampleRate = map.base.advanced(by: metaOffset + 44)
                    .load(as: Double.self)
                let channels = max(1, Int(map.base.advanced(by: metaOffset + 52)
                    .load(as: UInt32.self)))
                let data = Data(bytes: map.base + audioDataOffset
                                    + slot * audioSlotBytes,
                                count: byteCount)
                chunks.append(AudioChunk(
                    seq: seq, pts: pts.cmTime, data: data,
                    sampleRate: sampleRate, channels: channels))
                lastAudioSeq += 1
            }
            return chunks
        }

        var command: Command { map.command }
    }
}
