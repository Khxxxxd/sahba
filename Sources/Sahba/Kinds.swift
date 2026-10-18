import Foundation
import UniformTypeIdentifiers

/// What kind of files are being dragged. The wheel shows different choices for each.
enum FileKind: String {
    case image, video, audio, pdf, document, other

    /// Fake file name per kind, used by the snapshot test mode.
    var sampleName: String {
        switch self {
        case .image: return "photo.jpg"
        case .video: return "clip.mov"
        case .audio: return "song.mp3"
        case .pdf: return "file.pdf"
        case .document: return "notes.docx"
        case .other: return "folder"
        }
    }
}

enum Kinds {
    private static let documentTypes: [UTType] = [
        .rtf, .rtfd, .plainText, .html, .webArchive,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }

    static func type(_ url: URL) -> UTType? {
        if let t = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType { return t }
        return UTType(filenameExtension: url.pathExtension)
    }

    /// Formats macOS itself can't play, so their types don't say "movie" or "audio".
    private static let videoExts: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "ts", "mts", "m2ts", "3gp", "ogv"]
    private static let audioExts: Set<String> = ["flac", "ogg", "oga", "opus", "wma", "ape", "m4b"]

    static func kind(_ url: URL) -> FileKind {
        guard let t = type(url), !t.conforms(to: .folder), !t.conforms(to: .volume) else { return .other }
        if videoExts.contains(ext(url)) { return .video }
        if audioExts.contains(ext(url)) { return .audio }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if documentTypes.contains(where: { t.conforms(to: $0) }) { return .document }
        return .other
    }

    /// One kind for the whole selection; a mix counts as "other".
    static func groupKind(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(kind))
        return kinds.count == 1 ? kinds.first! : .other
    }

    static func ext(_ url: URL) -> String { url.pathExtension.lowercased() }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// Where results go: a new file next to the original, never over it.
enum Output {
    /// "Photo.heic" + "مضغوط" + "jpg" -> "Photo - مضغوط.jpg" (or "Photo - مضغوط 2.jpg" if taken).
    static func url(next url: URL, suffix: String? = nil, ext: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent + (suffix.map { " - \($0)" } ?? "")
        return unique(in: url.deletingLastPathComponent(), base: base, ext: ext)
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ b: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(b) : dir.appendingPathComponent(b).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }
}

enum OpError: LocalizedError {
    case unreadable, unwritable, missingTool(String), failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return tr("ما قدرت أقرا الملف", "Couldn't read the file")
        case .unwritable: return tr("ما قدرت أحفظ الناتج", "Couldn't save the result")
        case .missingTool(let t): return tr("يحتاج \(t)", "Needs \(t)")
        case .failed(let m): return m
        }
    }
}

/// Runs UI-bound work (text import, printing) on the main thread from any thread.
func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}
