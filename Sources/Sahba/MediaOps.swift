import AVFoundation
import Foundation

/// Runs ffmpeg/ffprobe and reports progress. Prefers the copy the installer puts in Application Support,
/// so nothing else (like Homebrew) needs to be installed.
enum FF {
    static var supportBin: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/Sahba/bin"
    }
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")

    private static func find(_ name: String) -> String? {
        [supportBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct Info {
        var duration: Double = 0
        var bitrate: Double = 0
        var vcodec: String?
        var acodec: String?
        var rotation: Double = 0
        var pixFmt = ""
        var transfer = ""

        /// 10-bit or HDR (HLG/PQ) video, like iPhone HDR or ProRes: must not be squeezed into 8-bit H.264.
        var isHighDepth: Bool { pixFmt.contains("10") || pixFmt.contains("12") || ["arib-std-b67", "smpte2084"].contains(transfer) }
    }

    static func info(_ url: URL) -> Info {
        var info = Info()
        guard let probe = ffprobe else { return info }
        let data = capture(probe, ["-v", "error", "-show_entries",
                                   "format=duration,bit_rate:stream=codec_type,codec_name,pix_fmt,color_transfer:stream_side_data=rotation",
                                   "-of", "json", url.path])
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return info }
        if let f = json["format"] as? [String: Any] {
            info.duration = Double(f["duration"] as? String ?? "") ?? 0
            info.bitrate = Double(f["bit_rate"] as? String ?? "") ?? 0
        }
        for s in json["streams"] as? [[String: Any]] ?? [] {
            let name = s["codec_name"] as? String
            switch s["codec_type"] as? String {
            case "video" where info.vcodec == nil:
                info.vcodec = name
                info.pixFmt = s["pix_fmt"] as? String ?? ""
                info.transfer = s["color_transfer"] as? String ?? ""
                for side in s["side_data_list"] as? [[String: Any]] ?? [] {
                    if let r = side["rotation"] as? Double { info.rotation = r }
                    if let r = side["rotation"] as? Int { info.rotation = Double(r) }
                }
            case "audio" where info.acodec == nil:
                info.acodec = name
            default: break
            }
        }
        return info
    }

    private static func capture(_ exe: String, _ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func run(_ args: [String], duration: Double, progress: (Double) -> Void) throws {
        guard let exe = ffmpeg else { throw OpError.missingTool("ffmpeg") }
        // Test hook: behave as if the Mac had no video encoder.
        if ProcessInfo.processInfo.environment["SAHBA_NO_VIDEOTOOLBOX"] != nil, let software = softwareFallback(args) {
            return try run(software, duration: duration, progress: progress)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var errData = Data()
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); errData.append(d); lock.unlock()
        }
        try p.run()
        var buffer = ""
        while true {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { break }
            buffer += String(decoding: d, as: UTF8.self)
            while let nl = buffer.firstIndex(of: "\n") {
                let line = buffer[..<nl]
                buffer.removeSubrange(...nl)
                if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                    progress(min(1, max(0, us / 1_000_000 / duration)))
                }
            }
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        if p.terminationStatus != 0, let software = softwareFallback(args) {
            // The Mac's video encoder isn't always there (seen on virtual M1 Macs with macOS 14): use x264/x265.
            Log.write("videotoolbox failed, retrying with the software encoder")
            return try run(software, duration: duration, progress: progress)
        }
        guard p.terminationStatus == 0 else {
            lock.lock(); let msg = String(decoding: errData, as: UTF8.self); lock.unlock()
            Log.write("ffmpeg failed \(args): \(msg.suffix(500))")
            let last = msg.split(separator: "\n").last.map(String.init) ?? tr("فشل", "failed")
            throw OpError.failed("ffmpeg: \(last)")
        }
    }
}

extension FF {
    private static let encoderList: String = {
        guard let exe = ffmpeg else { return "" }
        return String(decoding: capture(exe, ["-hide_banner", "-encoders"]), as: UTF8.self)
    }()

    /// Same job with the software encoders instead of VideoToolbox: x265 for HEVC (keeps 10-bit), x264 otherwise.
    static func softwareFallback(_ args: [String]) -> [String]? {
        guard let i = args.firstIndex(of: "-c:v"), i + 1 < args.count, args[i + 1].hasSuffix("_videotoolbox") else { return nil }
        var a = args
        func drop(_ flag: String) {
            if let j = a.firstIndex(of: flag), j + 1 < a.count { a.removeSubrange(j...(j + 1)) }
        }
        let constantQuality = a.contains("-q:v")
        drop("-q:v")
        let x265 = args[i + 1] == "hevc_videotoolbox" && encoderList.contains("libx265")
        if !x265 {
            drop("-profile:v")
            drop("-tag:v")
        }
        if let p = a.firstIndex(of: "p010le") { a[p] = x265 ? "yuv420p10le" : "yuv420p" }
        guard let c = a.firstIndex(of: "-c:v") else { return nil }
        a[c + 1] = x265 ? "libx265" : "libx264"
        var extra = ["-preset", "medium"]
        if constantQuality { extra += ["-crf", x265 ? "22" : "20"] }
        a.insert(contentsOf: extra, at: c + 2)
        return a
    }
}

/// A video or audio output format, with the ffmpeg arguments that make it.
struct MediaTarget {
    let target: Target
    let args: (FF.Info) -> [String]

    static let video: [MediaTarget] = [
        MediaTarget(target: Target(label: "MP4", ext: "mp4", aliases: ["m4v"])) { info in
            remuxOrEncode(info, copyV: ["h264", "hevc"], copyA: ["aac", "alac", "mp3"])
        },
        MediaTarget(target: Target(label: "MOV", ext: "mov", aliases: ["qt"])) { info in
            remuxOrEncode(info, copyV: ["h264", "hevc", "prores", "mjpeg"],
                          copyA: ["aac", "alac", "mp3", "pcm_s16le", "pcm_s24le", "pcm_s16be"])
        },
        MediaTarget(target: Target(label: "WebM", ext: "webm")) { _ in
            ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1",
             "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        },
        MediaTarget(target: Target(label: "GIF", ext: "gif")) { _ in
            ["-an", "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
             "-loop", "0"]
        },
        MediaTarget(target: Target(label: "MP3", ext: "mp3")) { _ in
            ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2"]
        },
        MediaTarget(target: Target(label: "M4A", ext: "m4a")) { _ in
            ["-vn", "-map", "0:a:0", "-c:a", "aac_at", "-b:a", "192k"]
        },
    ]

    static let audio: [MediaTarget] = [
        MediaTarget(target: Target(label: "MP3", ext: "mp3")) { _ in ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2"] },
        MediaTarget(target: Target(label: "M4A", ext: "m4a")) { _ in ["-vn", "-map", "0:a:0", "-c:a", "aac_at", "-b:a", "256k"] },
        MediaTarget(target: Target(label: "WAV", ext: "wav")) { _ in ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16le"] },
        MediaTarget(target: Target(label: "FLAC", ext: "flac")) { _ in ["-vn", "-map", "0:a:0", "-c:a", "flac"] },
        MediaTarget(target: Target(label: "AIFF", ext: "aiff", aliases: ["aif"])) { _ in ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16be"] },
        MediaTarget(target: Target(label: "OPUS", ext: "opus")) { _ in ["-vn", "-map", "0:a:0", "-c:a", "libopus", "-b:a", "128k"] },
    ]

    /// Re-packs without re-encoding when the codecs fit the new container (instant and lossless).
    private static func remuxOrEncode(_ info: FF.Info, copyV: Set<String>, copyA: Set<String>) -> [String] {
        let keepV = copyV.contains(info.vcodec ?? "")
        let keepA = info.acodec == nil || copyA.contains(info.acodec ?? "")
        var a = ["-map", "0:v:0", "-map", "0:a?"]
        if keepV {
            a += ["-c:v", "copy"]
        } else if info.isHighDepth {
            // Keep 10-bit HDR: HEVC Main10 on the Mac's video encoder (what iPhone itself records).
            a += ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "65", "-tag:v", "hvc1"]
        } else {
            a += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
        }
        a += keepA ? ["-c:a", "copy"] : ["-c:a", "aac_at", "-b:a", "192k"]
        if keepV && info.vcodec == "hevc" { a += ["-tag:v", "hvc1"] }
        // iPhone HDR is Dolby Vision on top of HLG; ffmpeg only keeps its config box with "unofficial".
        if keepV { a += ["-strict", "unofficial"] }
        return a + ["-movflags", "+faststart"]
    }
}

enum MediaOps {
    static func convert(_ url: URL, to t: MediaTarget, progress: (Double) -> Void) throws -> URL {
        let info = FF.info(url)
        let out = Output.url(next: url, ext: t.target.ext)
        do {
            try FF.run(["-i", url.path] + t.args(info) + [out.path], duration: info.duration, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    /// `fraction` is the wanted size compared with the original (0.1…0.9).
    static func compressVideo(_ url: URL, fraction: Double, progress: (Double) -> Void) throws -> URL {
        let info = FF.info(url)
        guard info.duration > 0 else { throw OpError.unreadable }
        let total = Double(Kinds.size(url)) * 8 * fraction / info.duration
        let videoBits = max(150_000, total - 128_000)
        let out = Output.url(next: url, suffix: tr("مضغوط", "Compressed"), ext: "mp4")
        try FF.run(["-i", url.path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "hevc_videotoolbox",
                    "-b:v", String(Int(videoBits)), "-tag:v", "hvc1", "-c:a", "aac_at", "-b:a", "128k",
                    "-movflags", "+faststart", out.path], duration: info.duration, progress: progress)
        return out
    }

    static func compressAudio(_ url: URL, fraction: Double, progress: (Double) -> Void) throws -> URL {
        let info = FF.info(url)
        var original = info.bitrate
        if original <= 0, info.duration > 0 { original = Double(Kinds.size(url)) * 8 / info.duration }
        let bitrate = String(Int(min(320_000, max(48_000, original * fraction))))
        let e = Kinds.ext(url)
        let (codec, ext): (String, String)
        switch e {
        case "mp3": (codec, ext) = ("libmp3lame", "mp3")
        case "opus", "ogg": (codec, ext) = ("libopus", e)
        default: (codec, ext) = ("aac_at", "m4a")
        }
        let out = Output.url(next: url, suffix: tr("مضغوط", "Compressed"), ext: ext)
        try FF.run(["-i", url.path, "-vn", "-map", "0:a:0", "-c:a", codec, "-b:a", bitrate, out.path],
                   duration: info.duration, progress: progress)
        return out
    }

    /// Frame-accurate and lossless for MOV/MP4/M4A (AVFoundation); ffmpeg stream copy for the rest.
    static func trim(_ url: URL, start: Double, end: Double, progress: @escaping (Double) -> Void) throws -> URL {
        let e = Kinds.ext(url)
        let out = Output.url(next: url, suffix: tr("مقصوص", "Trimmed"), ext: e)
        let types: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v, "m4a": .m4a]
        if let type = types[e] {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw OpError.unreadable
            }
            session.outputURL = out
            session.outputFileType = type
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                            end: CMTime(seconds: end, preferredTimescale: 600))
            let done = DispatchSemaphore(value: 0)
            session.exportAsynchronously { done.signal() }
            while done.wait(timeout: .now() + 0.1) == .timedOut { progress(Double(session.progress)) }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: out)
                throw OpError.failed(session.error?.localizedDescription ?? tr("ما زبط القص", "Trim failed"))
            }
            return out
        }
        try FF.run(["-ss", String(start), "-to", String(end), "-i", url.path, "-map", "0", "-c", "copy", out.path],
                   duration: end - start, progress: progress)
        return out
    }

    static let rotatable: Set<String> = ["mov", "mp4", "m4v"]

    private static let avTypes: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v]

    /// Copies the video and audio tracks (not the camera's timed-metadata tracks) without re-encoding,
    /// optionally with a new display rotation and with all file metadata removed.
    private static func avRewrap(_ url: URL, to out: URL, extraRotation: CGFloat?, clearMetadata: Bool) throws {
        guard let type = avTypes[Kinds.ext(url)] else { throw OpError.unreadable }
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        for track in asset.tracks where track.mediaType == .video || track.mediaType == .audio {
            guard let ct = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try ct.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video {
                var t = track.preferredTransform
                if let angle = extraRotation {
                    t = t.concatenating(CGAffineTransform(rotationAngle: angle))
                    let box = CGRect(origin: .zero, size: track.naturalSize).applying(t)
                    t = t.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                }
                ct.preferredTransform = t
            }
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw OpError.unreadable }
        session.outputURL = out
        session.outputFileType = type
        if clearMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        } else {
            session.metadata = asset.metadata
        }
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw OpError.failed(session.error?.localizedDescription ?? tr("ما زبط", "Failed"))
        }
    }

    /// Turns the video 90° clockwise by changing its display rotation (no re-encoding).
    static func rotateVideo(_ url: URL) throws -> URL {
        let avOut = Output.url(next: url, suffix: tr("مدوّر", "Rotated"), ext: Kinds.ext(url))
        if (try? avRewrap(url, to: avOut, extraRotation: .pi / 2, clearMetadata: false)) != nil { return avOut }
        let info = FF.info(url)
        var angle = info.rotation - 90
        while angle <= -180 { angle += 360 }
        let out = Output.url(next: url, suffix: tr("مدوّر", "Rotated"), ext: Kinds.ext(url))
        try FF.run(["-display_rotation:v:0", String(Int(angle)), "-i", url.path, "-map", "0:v:0", "-map", "0:a?",
                    "-c", "copy", out.path], duration: info.duration) { _ in }
        return out
    }

    static func stripMetadata(_ url: URL, audioOnly: Bool) throws -> URL {
        let out = Output.url(next: url, suffix: tr("بدون بيانات", "No Metadata"), ext: Kinds.ext(url))
        if !audioOnly, (try? avRewrap(url, to: out, extraRotation: nil, clearMetadata: true)) != nil { return out }
        let info = FF.info(url)
        let maps = audioOnly ? ["-map", "0:a"] : ["-map", "0:v:0", "-map", "0:a?"]
        try FF.run(["-i", url.path] + maps + ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact",
                    "-c", "copy", out.path], duration: info.duration) { _ in }
        return out
    }
}
