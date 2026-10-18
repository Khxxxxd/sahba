import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// An output format, with the file extensions that already count as that format.
struct Target {
    let label: String
    let ext: String
    var aliases: Set<String> = []
    var uti: String = ""

    func matches(_ url: URL) -> Bool {
        let e = Kinds.ext(url)
        return e == ext || aliases.contains(e)
    }

    static let png = Target(label: "PNG", ext: "png", uti: "public.png")
    static let jpg = Target(label: "JPG", ext: "jpg", aliases: ["jpeg", "jpe"], uti: "public.jpeg")
    static let heic = Target(label: "HEIC", ext: "heic", aliases: ["heif"], uti: "public.heic")
    static let avif = Target(label: "AVIF", ext: "avif", uti: "public.avif")
    static let tiff = Target(label: "TIFF", ext: "tiff", aliases: ["tif"], uti: "public.tiff")
    static let pdf = Target(label: "PDF", ext: "pdf", uti: "com.adobe.pdf")
}

/// Image work with the Mac's own ImageIO. Every result is a new file next to the original.
enum ImageOps {
    /// macOS 14 and 15 read AVIF but can't write it (seen on clean M1 Macs); macOS 26 can.
    static let canWriteAVIF = ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("public.avif")

    static func open(_ url: URL) throws -> (CGImageSource, [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw OpError.unreadable
        }
        return (src, (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:])
    }

    // MARK: Convert

    static func convert(_ url: URL, to t: Target) throws -> URL {
        let (src, props) = try open(url)
        let out = Output.url(next: url, ext: t.ext)
        if t.ext == "pdf" {
            try writePDF([(src, props)], to: out)
        } else if hasGainMap(src), try saveHDR(url, src: src, props: props, uti: t.uti, quality: 0.9, keepMetadata: true, to: out) {
            // HDR kept through the gain map.
        } else {
            try encode(src, props: props, uti: t.uti, quality: 0.9, to: out)
        }
        return out
    }

    // MARK: Tools

    /// Lossy formats stay as they are; anything else becomes JPG (or HEIC if it has transparency).
    static func compressedTarget(_ url: URL, props: [CFString: Any]) -> Target {
        for t in [Target.jpg, .heic, .avif] where t.matches(url) { return t.ext == "avif" && !canWriteAVIF ? .heic : t }
        return ((props[kCGImagePropertyHasAlpha] as? Bool) ?? false) ? .heic : .jpg
    }

    static func compress(_ url: URL, quality: Double) throws -> URL {
        let (src, props) = try open(url)
        let t = compressedTarget(url, props: props)
        let out = Output.url(next: url, suffix: tr("مضغوط", "Compressed"), ext: t.ext)
        if hasGainMap(src), try saveHDR(url, src: src, props: props, uti: t.uti, quality: quality, keepMetadata: true, to: out) { return out }
        try encode(src, props: props, uti: t.uti, quality: quality, to: out)
        return out
    }

    /// Size in bytes the compressed file would have, without saving anything.
    static func estimate(_ url: URL, quality: Double) -> Int? {
        guard let (src, props) = try? open(url) else { return nil }
        let t = compressedTarget(url, props: props)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, t.uti as CFString, 1, nil) else { return nil }
        add(src, props: props, uti: t.uti, quality: quality, to: dest)
        return CGImageDestinationFinalize(dest) ? data.length : nil
    }

    static func rotate(_ url: URL) throws -> URL {
        let (src, props) = try open(url)
        let fmt = sameFormat(src, url)
        if hasGainMap(src) {
            let lossy = hdrFormat(fmt)
            let out = Output.url(next: url, suffix: tr("مدوّر", "Rotated"), ext: lossy.ext)
            if try saveHDR(url, src: src, props: props, uti: lossy.uti, quality: 0.92, keepMetadata: true, to: out,
                           edit: { $0.oriented(.right) }) { return out }
        }
        guard let image = orientedImage(src, props: props),
              let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgbSpace(image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OpError.unreadable }
        // 90° clockwise.
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = ctx.makeImage() else { throw OpError.unwritable }
        let out = Output.url(next: url, suffix: tr("مدوّر", "Rotated"), ext: fmt.ext)
        try write(rotated, uti: fmt.uti, props: props, to: out)
        return out
    }

    /// `rect` is normalised (0…1) with the origin at the top-left of the upright image.
    static func crop(_ url: URL, rect: CGRect) throws -> URL {
        let (src, props) = try open(url)
        let fmt = sameFormat(src, url)
        if hasGainMap(src) {
            let lossy = hdrFormat(fmt)
            let out = Output.url(next: url, suffix: tr("مقصوص", "Cropped"), ext: lossy.ext)
            let crop: (CIImage) -> CIImage = { img in
                let e = img.extent // Core Image counts from the bottom
                return img.cropped(to: CGRect(x: e.minX + rect.minX * e.width, y: e.minY + (1 - rect.maxY) * e.height,
                                              width: rect.width * e.width, height: rect.height * e.height).integral)
            }
            if try saveHDR(url, src: src, props: props, uti: lossy.uti, quality: 0.92, keepMetadata: true, to: out, edit: crop) { return out }
        }
        guard let image = orientedImage(src, props: props) else { throw OpError.unreadable }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let px = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
        guard let cropped = image.cropping(to: px) else { throw OpError.failed(tr("ما قدرت أقص", "Couldn't crop")) }
        let out = Output.url(next: url, suffix: tr("مقصوص", "Cropped"), ext: fmt.ext)
        try write(cropped, uti: fmt.uti, props: props, to: out)
        return out
    }

    /// Removes camera, location and other hidden data. Keeps the pixels untouched when the format allows it.
    static func stripMetadata(_ url: URL) throws -> URL {
        let (src, props) = try open(url)
        let fmt = sameFormat(src, url)
        let uti = fmt.uti
        let out = Output.url(next: url, suffix: tr("بدون بيانات", "No Metadata"), ext: fmt.ext)
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let native = (CGImageSourceGetType(src) as String?) == uti

        // RAW (ProRAW DNG) can't be written back: save HEIC, keeping HDR, with no metadata.
        if !native, hasGainMap(src), try saveHDR(url, src: src, props: props, uti: uti, quality: 0.95, keepMetadata: false, to: out) {
            return out
        }
        if native, let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) {
            let meta = CGImageMetadataCreateMutable()
            if orientation != 1 {
                _ = CGImageMetadataSetValueMatchingImageProperty(
                    meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
            let opts: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, nil) { return out }
            try? FileManager.default.removeItem(at: out)
        }
        // Fallback: re-encode with nothing but the rotation.
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else { throw OpError.unwritable }
        let opts: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OpError.unwritable }
        return out
    }

    /// All images into one PDF, one page each, named after the first image.
    static func mergeToPDF(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw OpError.unreadable }
        let pages = try urls.map { try open($0) }
        let out = Output.url(next: first, suffix: tr("مدموج", "Merged"), ext: "pdf")
        try writePDF(pages, to: out)
        return out
    }

    // MARK: Helpers

    static func orientedImage(_ src: CGImageSource, props: [CFString: Any]) -> CGImage? {
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func orientedImage(_ url: URL) -> CGImage? {
        guard let (src, props) = try? open(url) else { return nil }
        return orientedImage(src, props: props)
    }

    /// The source's own format when the Mac can write it; HEIC for formats it can only read (RAW/DNG).
    private static func sameFormat(_ src: CGImageSource, _ url: URL) -> (uti: String, ext: String) {
        let t = (CGImageSourceGetType(src) as String?) ?? ""
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(t) ? (t, Kinds.ext(url)) : ("public.heic", "heic")
    }

    // MARK: HDR photos (iPhone HDR and ProRAW keep their extra brightness in a "gain map")

    static func hasGainMap(_ src: CGImageSource) -> Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { return true }
        if #available(macOS 15.0, *) {
            return CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        return false
    }

    private static let gainMapFormats: Set<String> = ["public.jpeg", "public.heic", "public.avif"]

    /// Edits (rotate, crop) on HDR photos stay JPG/HEIC/AVIF so the gain map survives; anything else becomes HEIC.
    private static func hdrFormat(_ fmt: (uti: String, ext: String)) -> (uti: String, ext: String) {
        gainMapFormats.contains(fmt.uti) ? fmt : ("public.heic", "heic")
    }

    /// Saves an HDR photo as JPG/HEIC/AVIF with a gain map. `edit` runs on the upright picture.
    /// Returns false when that isn't possible here (older macOS, PNG/TIFF), so the caller saves normally.
    private static func saveHDR(_ url: URL, src: CGImageSource, props: [CFString: Any], uti: String, quality: Double,
                                keepMetadata: Bool, to out: URL, edit: ((CIImage) -> CIImage)? = nil) throws -> Bool {
        guard #available(macOS 15.0, *), gainMapFormats.contains(uti) else { return false }
        if uti == "public.avif" {
            // Core Image can't write AVIF: render the upright HDR picture and let ImageIO add an ISO gain map.
            guard var hdr = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
                throw OpError.unreadable
            }
            if let edit { hdr = edit(hdr) }
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                  let image = CIContext().createCGImage(hdr, from: hdr.extent, format: .RGBAh, colorSpace: space),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else { throw OpError.unwritable }
            var opts = keepMetadata ? metadata(props, extra: [:]) : [kCGImagePropertyOrientation: 1]
            opts[kCGImageDestinationLossyCompressionQuality] = quality
            opts[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            CGImageDestinationAddImage(dest, image, opts as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw OpError.unwritable }
            return true
        }
        guard var sdr = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              var hdr = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
            throw OpError.unreadable
        }
        var meta: [String: Any] = keepMetadata ? sdr.properties : [:]
        meta[kCGImagePropertyOrientation as String] = 1 // the pixels are upright now
        if var tiff = meta[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            meta[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let edit { sdr = edit(sdr); hdr = edit(hdr) }
        sdr = sdr.settingProperties(meta)
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CIContext()
        if uti == "public.jpeg" {
            try ctx.writeJPEGRepresentation(of: sdr, to: out, colorSpace: space, options: options)
        } else {
            try ctx.writeHEIFRepresentation(of: sdr, to: out, format: .RGBA8, colorSpace: space, options: options)
        }
        return true
    }

    private static func rgbSpace(_ image: CGImage) -> CGColorSpace {
        if let s = image.colorSpace, s.model == .rgb { return s }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private static func encode(_ src: CGImageSource, props: [CFString: Any], uti: String, quality: Double, to out: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw OpError.unwritable
        }
        add(src, props: props, uti: uti, quality: quality, to: dest)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: out)
            throw OpError.unwritable
        }
    }

    private static func add(_ src: CGImageSource, props: [CFString: Any], uti: String, quality: Double, to dest: CGImageDestination) {
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let flatten = uti == "public.jpeg" && ((props[kCGImagePropertyHasAlpha] as? Bool) ?? false)
        let q: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if orientation == 1 && !flatten {
            // Straight copy keeps the full colour depth and all metadata.
            CGImageDestinationAddImageFromSource(dest, src, 0, q as CFDictionary)
            return
        }
        // Bake the rotation into the pixels (PNG viewers often ignore the tag); JPG gets a white background.
        guard var image = orientedImage(src, props: props) else { return }
        if flatten, let flat = onWhite(image) { image = flat }
        CGImageDestinationAddImage(dest, image, metadata(props, extra: q) as CFDictionary)
    }

    private static func write(_ image: CGImage, uti: String, props: [CFString: Any], to out: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw OpError.unwritable
        }
        CGImageDestinationAddImage(dest, image, metadata(props, extra: [kCGImageDestinationLossyCompressionQuality: 0.92]) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OpError.unwritable }
    }

    /// The original metadata, minus the rotation tag (the pixels are already upright).
    private static func metadata(_ props: [CFString: Any], extra: [CFString: Any]) -> [CFString: Any] {
        var meta = extra
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = props[key] { meta[key] = v }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyOrientation] = 1
        return meta
    }

    private static func onWhite(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: rgbSpace(image),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    private static func asJPEG(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func writePDF(_ pages: [(CGImageSource, [CFString: Any])], to out: URL) throws {
        let info: [CFString: Any] = [kCGPDFContextCreator: "Sahba"]
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, info as CFDictionary) else { throw OpError.unwritable }
        for (src, props) in pages {
            guard var image = orientedImage(src, props: props) else { continue }
            // Embed as JPEG so the PDF stays about the size of the photo (raw pixels are huge).
            if !((props[kCGImagePropertyHasAlpha] as? Bool) ?? false), let jpeg = asJPEG(image) { image = jpeg }
            var dpi = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
            if dpi <= 0 { dpi = 72 }
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard FileManager.default.fileExists(atPath: out.path) else { throw OpError.unwritable }
    }
}
