import AppKit
import PDFKit
import Quartz

/// PDF and text-document work with PDFKit and the Mac's text system.
enum DocOps {
    // MARK: PDF -> other

    /// One image per page at 300 DPI. Several pages go into a folder "name - صفحات".
    static func pdfToImages(_ url: URL, to t: Target, progress: (Double) -> Void) throws -> [URL] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw OpError.unreadable }
        let uti = t.uti as CFString
        var dir = url.deletingLastPathComponent()
        if doc.pageCount > 1 {
            dir = Output.unique(in: dir, base: url.deletingPathExtension().lastPathComponent + tr(" - صفحات", " - Pages"), ext: "")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let image = render(page, dpi: 300) else { continue }
            let out = doc.pageCount > 1
                ? Output.unique(in: dir, base: String(i + 1), ext: t.ext)
                : Output.url(next: url, ext: t.ext)
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti, 1, nil) else { throw OpError.unwritable }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw OpError.unwritable }
            outputs.append(out)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return doc.pageCount > 1 ? [dir] : outputs
    }

    private static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let boxChoice: PDFDisplayBox = page.bounds(for: .cropBox).isEmpty ? .mediaBox : .cropBox
        let box = page.bounds(for: boxChoice)
        let quarterTurns = (page.rotation / 90) % 2 != 0
        let size = quarterTurns ? CGSize(width: box.height, height: box.width) : box.size
        // 300 DPI, but never more than 6000 px on a side (image-only PDFs can have giant pages).
        let scale = min(dpi / 72, 6000 / max(size.width, size.height, 1))
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.transform(for: boxChoice))
        page.draw(with: boxChoice, to: ctx)
        return ctx.makeImage()
    }

    static func pdfToText(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable }
        let out = Output.url(next: url, ext: "txt")
        try fixArabic(doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func pdfToRich(_ url: URL, to t: DocTarget) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable }
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.attributedString { text.append(page) }
            if i < doc.pageCount - 1 { text.append(NSAttributedString(string: "\n\n")) }
        }
        let fixed = NSMutableAttributedString()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            fixed.append(NSAttributedString(string: fixArabic((text.string as NSString).substring(with: range)), attributes: attrs))
        }
        setArabicDirection(fixed)
        let out = Output.url(next: url, ext: t.target.ext)
        try write(fixed, as: t, to: out)
        return out
    }

    /// PDFs often store Arabic as "presentation forms" (one code per letter shape); turn them back into letters.
    static func fixArabic(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0xFB50...0xFDFF).contains(u.value) || (0xFE70...0xFEFE).contains(u.value) {
                out.append(contentsOf: String(u).precomposedStringWithCompatibilityMapping.unicodeScalars)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    // MARK: PDF tools

    static func compressPDF(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable }
        let out = Output.url(next: url, suffix: tr("مضغوط", "Compressed"), ext: "pdf")
        // The same "Reduce File Size" filter Preview uses; PDFKit's own image options barely shrink anything.
        let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
        let ok = filter.map { doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): $0]) }
            ?? doc.write(to: out)
        guard ok else { throw OpError.unwritable }
        return out
    }

    static func mergePDFs(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw OpError.unreadable }
        let merged = PDFDocument()
        for url in urls {
            guard let doc = PDFDocument(url: url) else { throw OpError.unreadable }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    if let pageCopy = page.copy() as? PDFPage {
                        merged.insert(pageCopy, at: merged.pageCount)
                    } else {
                        merged.insert(page, at: merged.pageCount)
                    }
                }
            }
        }
        let out = Output.url(next: first, suffix: tr("مدموج", "Merged"), ext: "pdf")
        guard merged.write(to: out) else { throw OpError.unwritable }
        return out
    }

    static func stripPDF(_ url: URL) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw OpError.unreadable }
        doc.documentAttributes = [:]
        let out = Output.url(next: url, suffix: tr("بدون بيانات", "No Metadata"), ext: "pdf")
        guard doc.write(to: out) else { throw OpError.unwritable }
        return out
    }

    // MARK: Documents

    static func convertDocument(_ url: URL, to t: DocTarget) throws -> URL {
        let text = try read(url)
        let out = Output.url(next: url, ext: t.target.ext)
        try write(text, as: t, to: out)
        return out
    }

    private static func read(_ url: URL) throws -> NSMutableAttributedString {
        let plain: Set<String> = ["txt", "text", "md", "markdown", "csv", "log"]
        if plain.contains(Kinds.ext(url)) {
            let s: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) { s = utf8 } else { s = try String(contentsOf: url, encoding: .utf16) }
            let text = NSMutableAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            setArabicDirection(text)
            return text
        }
        // HTML import uses WebKit, which must run on the main thread.
        return try onMain {
            NSMutableAttributedString(attributedString: try NSAttributedString(url: url, options: [:], documentAttributes: nil))
        }
    }

    private static func write(_ text: NSAttributedString, as t: DocTarget, to out: URL) throws {
        switch t.kind {
        case .txt:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .pdf:
            try onMain { try printPDF(text, to: out) }
        case .rich(let type):
            var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            try data.write(to: out)
        }
    }

    /// A4 pages laid out by the Mac's text system, then saved as PDF.
    private static func printPDF(_ text: NSAttributedString, to out: URL) throws {
        let paper = NSSize(width: 595, height: 842), margin: CGFloat = 56
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - 2 * margin, height: 100))
        view.textStorage?.setAttributedString(withGeezaForArabic(text))
        // Let the view grow to fit; forcing layout by hand first reverses Arabic words in the PDF's text.
        view.isVerticallyResizable = true
        view.sizeToFit()
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else { throw OpError.unwritable }
    }

    /// Text with Arabic is set in Geeza Pro: it stays copyable and searchable in the PDF, while the
    /// system Arabic font (or a mix of fonts) comes out garbled when the PDF is read back.
    private static func withGeezaForArabic(_ text: NSAttributedString) -> NSAttributedString {
        guard text.string.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else { return text }
        let m = NSMutableAttributedString(attributedString: text)
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            let old = value as? NSFont
            let bold = old?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            if let f = NSFont(name: bold ? "GeezaPro-Bold" : "GeezaPro", size: old?.pointSize ?? 13) {
                m.addAttribute(.font, value: f, range: range)
            }
        }
        return m
    }

    /// Paragraphs that start with Arabic read right-to-left (Word and PDF otherwise show them left-aligned).
    private static func setArabicDirection(_ text: NSMutableAttributedString) {
        let s = text.string as NSString
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub, let first = sub.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }),
                  (0x0600...0x06FF).contains(first.value) || (0xFB50...0xFEFF).contains(first.value) else { return }
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = .rightToLeft
            style.alignment = .right
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }
}

/// A text-document output format.
struct DocTarget {
    enum Kind { case txt, pdf, rich(NSAttributedString.DocumentType) }
    let target: Target
    let kind: Kind

    static let docx = DocTarget(target: Target(label: "DOCX", ext: "docx"), kind: .rich(.officeOpenXML))
    static let pdf = DocTarget(target: .pdf, kind: .pdf)
    static let txt = DocTarget(target: Target(label: "TXT", ext: "txt", aliases: ["text"]), kind: .txt)
    static let rtf = DocTarget(target: Target(label: "RTF", ext: "rtf"), kind: .rich(.rtf))
    static let html = DocTarget(target: Target(label: "HTML", ext: "html", aliases: ["htm"]), kind: .rich(.html))
    static let odt = DocTarget(target: Target(label: "ODT", ext: "odt"), kind: .rich(.openDocument))
}
