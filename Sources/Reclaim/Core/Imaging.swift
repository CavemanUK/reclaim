import CoreGraphics
import Foundation
import ImageIO
import Vision

// Image helpers shared by the photo features: decoding thumbnails, the perceptual hash, a sharpness metric and
// thin wrappers around Vision. `SimilarPhotoFinder` and `PhotoClearouts` combine these into their pipelines.

/// Stateless image utilities. Everything here only reads image data.
enum Imaging {
    /// File extensions treated as photos when scanning folders, including common RAW formats.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng", "cr2", "cr3", "nef", "arw",
    ]

    /// True for iCloud "cloud-only" placeholders. Reading one would make macOS download it, so we never do.
    ///
    /// A "dataless" file (the `SF_DATALESS` flag) has its directory entry locally but no content. Callers skip
    /// these, since opening them would start a download and use data and disk space.
    static func isCloudOnly(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & 0x4000_0000) != 0   // SF_DATALESS
    }

    /// Decodes a downscaled copy with the longest side at most `maxPixel`, applying the EXIF orientation.
    /// Much cheaper than decoding the full image, and nothing is cached by ImageIO.
    static func thumbnail(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Reads the pixel dimensions from the file's metadata without decoding the image.
    static func pixelSize(path: String) -> (width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// 64-bit difference hash: robust to resizing and recompression.
    ///
    /// Draws the image into a 9x8 greyscale grid and sets one bit per pixel for whether it is brighter than its right
    /// neighbour. Near-identical images give hashes a few bits apart (small Hamming distance), which makes this a
    /// fast first filter before the more expensive Vision feature prints.
    static func differenceHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    /// Variance of the Laplacian on a mid-size grayscale copy. Higher means sharper; blur drives it toward 0.
    ///
    /// Used as a quality signal when choosing which photo of a similar set to keep.
    static func sharpness(_ image: CGImage) -> Double {
        let w = 384
        let h = max(8, Int(Double(image.height) / Double(max(1, image.width)) * Double(w)))
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * Double(px[i]) - Double(px[i - 1]) - Double(px[i + 1]) - Double(px[i - w]) - Double(px[i + w])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        let variance = sumSq / n - mean * mean
        return variance.isFinite ? max(0, variance) : 0
    }

    /// Apple's own judgement of a photo: overall aesthetic score and how well any faces were captured.
    ///
    /// Both values come from Vision's async requests, so unlike the other Vision helpers this one is `async`.
    static func appleScores(_ image: CGImage) async -> (aesthetics: Double?, face: Double?, faceCount: Int) {
        var aesthetics: Double?
        // The model occasionally answers NaN (seen on some old JPEGs); treat that as "no opinion".
        if let obs = try? await CalculateImageAestheticsScoresRequest().perform(on: image, orientation: nil),
            obs.overallScore.isFinite
        {
            aesthetics = Double(obs.overallScore)
        }
        var face: Double?
        var count = 0
        if let faces = try? await DetectFaceCaptureQualityRequest().perform(on: image, orientation: nil) {
            let scores = faces.compactMap { $0.captureQuality?.score }.map(Double.init)
            count = faces.count
            if !scores.isEmpty { face = scores.reduce(0, +) / Double(scores.count) }
        }
        return (aesthetics, face, count)
    }

    /// How much readable text is in the picture: total recognised characters and how many of them are digits.
    /// Fast on-device OCR; blocking, so call from a dedicated thread.
    static func textAmount(_ image: CGImage) -> (characters: Int, digits: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return (0, 0) }
        var chars = 0, digits = 0
        for obs in request.results ?? [] {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            chars += text.count
            digits += text.filter(\.isNumber).count
        }
        return (chars, digits)
    }

    /// Apple's image classifier labels above `minConfidence`. Blocking.
    static func labels(_ image: CGImage, minConfidence: Float = 0.3) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).filter { $0.confidence >= minConfidence }.map(\.identifier)
    }

    /// Apple's on-device image embedding. Distance between two prints is small for visually similar photos.
    ///
    /// Blocking, so it is run through `blockingParallelMap`.
    static func featurePrint(of image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }
}
