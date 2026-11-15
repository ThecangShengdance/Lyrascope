//
//  Lyrics.swift
//  Lyrascope
//
//  LRC 解析 + 歌词模型。LRC 是纯文本时间轴格式，这里完全自己实现，
//  没有引入任何第三方歌词库。
//

import Foundation

// MARK: - 模型

enum LyricsSource: String, Codable {
    case localFile
    case cache
    case lrclib
    case appleMusic
    case embedded
    case plainText

    var label: String {
        switch self {
        case .localFile: return "本地 LRC"
        case .cache: return "缓存"
        case .lrclib: return "LRCLIB"
        case .appleMusic: return "Apple Music"
        case .embedded: return "内嵌歌词"
        case .plainText: return "纯文本"
        }
    }
}

struct LyricWord: Equatable {
    var time: Double
    var text: String
}

struct LyricLine: Equatable, Identifiable {
    var id: Int
    var time: Double
    var text: String
    var translation: String?
    var words: [LyricWord] = []

    var displayText: String { text }
}

struct LyricsDocument: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var offset: Double = 0
    var isSynced: Bool = true
    /// 时间轴是按曲长平均估出来的（纯文本歌词的兜底方案），不是原始时间戳。
    var isEstimated: Bool = false
    var source: LyricsSource = .plainText
    var lines: [LyricLine] = []

    var hasTranslations: Bool {
        lines.contains { $0.translation?.isEmpty == false }
    }

    /// 把每一行的翻译补进来（不覆盖已有翻译）。
    mutating func mergeTranslations(_ map: [Int: String]) {
        guard !map.isEmpty else { return }
        for index in lines.indices {
            guard lines[index].translation?.isEmpty != false,
                  let text = map[index], !text.isEmpty else { continue }
            lines[index].translation = text
        }
    }

    /// 纯文本歌词没有时间戳时，按曲长把行均匀排开，让它至少能跟着音乐往下走。
    mutating func applyEstimatedTiming(duration: Double) {
        guard !isSynced, duration > 25, lines.count > 3 else { return }
        let usable = max(20, duration - 4)
        let step = usable / Double(lines.count)
        for index in lines.indices {
            lines[index].time = 2.0 + Double(index) * step
        }
        isSynced = true
        isEstimated = true
    }

    var isEmpty: Bool { lines.isEmpty }

    /// 返回最后一个时间 <= position 的行号，没有则 -1。
    func index(at position: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        var low = 0
        var high = lines.count - 1
        var result = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    func endTime(of index: Int) -> Double {
        guard index >= 0, index < lines.count else { return 0 }
        if index + 1 < lines.count {
            return lines[index + 1].time
        }
        let text = lines[index].text
        return lines[index].time + max(2.0, Double(text.count) * 0.22)
    }
}

// MARK: - LRC 解析器

enum LRCParser {

    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let wordRegex = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#
    )
    private static let metadataRegex = try! NSRegularExpression(
        pattern: #"^\[(ti|ar|al|by|offset|length|re|ve|au):(.*)\]$"#,
        options: [.caseInsensitive]
    )

    static func parse(_ raw: String, source: LyricsSource = .plainText) -> LyricsDocument {
        var document = LyricsDocument(source: source)
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var entries: [(time: Double, text: String, words: [LyricWord])] = []
        var plainLines: [String] = []
        var offsetMs: Double = 0
        var hasTimestamp = false

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let match = metadataRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let key = (line as NSString).substring(with: match.range(at: 1)).lowercased()
                let value = (line as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                switch key {
                case "ti": document.title = value
                case "ar": document.artist = value
                case "al": document.album = value
                case "offset": offsetMs = Double(value) ?? 0
                default: break
                }
                continue
            }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = timestampRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty, matches[0].range.location == 0 else {
                if !line.hasPrefix("[") { plainLines.append(line) }
                continue
            }

            // 行首连续的若干时间戳，对应同一句歌词。
            var times: [Double] = []
            var consumed = 0
            for match in matches {
                guard match.range.location == consumed else { break }
                times.append(seconds(from: nsLine, match: match))
                consumed = match.range.location + match.range.length
            }
            guard !times.isEmpty else { continue }

            let remainder = nsLine.substring(from: consumed)
            let (text, words) = extractWords(from: remainder)
            guard !text.isEmpty else { continue }
            hasTimestamp = true
            for time in times {
                entries.append((time, text, words))
            }
        }

        document.offset = offsetMs / 1000

        if hasTimestamp {
            entries.sort { $0.time < $1.time }
            var lines: [LyricLine] = []
            var index = 0
            for entry in entries {
                let time = max(0, entry.time - document.offset)
                if let last = lines.last, abs(last.time - time) < 0.035, !last.text.isEmpty, last.translation == nil, last.text != entry.text {
                    // 同一时间戳的第二行当作翻译。
                    lines[lines.count - 1].translation = entry.text
                    continue
                }
                if let last = lines.last, abs(last.time - time) < 0.035, last.text == entry.text {
                    continue
                }
                lines.append(
                    LyricLine(
                        id: index,
                        time: time,
                        text: entry.text,
                        translation: nil,
                        words: entry.words
                    )
                )
                index += 1
            }
            document.lines = lines
            document.isSynced = true
        } else if !plainLines.isEmpty {
            document.lines = plainLines.enumerated().map { offset, text in
                LyricLine(id: offset, time: 0, text: text)
            }
            document.isSynced = false
        }

        return document
    }

    private static func seconds(from line: NSString, match: NSTextCheckingResult) -> Double {
        let minutes = Double(line.substring(with: match.range(at: 1))) ?? 0
        let secs = Double(line.substring(with: match.range(at: 2))) ?? 0
        var fraction = 0.0
        if match.range(at: 3).location != NSNotFound {
            let rawFraction = line.substring(with: match.range(at: 3))
            if let value = Double(rawFraction) {
                fraction = value / pow(10, Double(rawFraction.count))
            }
        }
        return minutes * 60 + secs + fraction
    }

    /// 解析增强 LRC 的 `<mm:ss.xx>` 逐字标签，返回去掉标签的文本与词时间。
    private static func extractWords(from raw: String) -> (String, [LyricWord]) {
        let nsRaw = raw as NSString
        let matches = wordRegex.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard !matches.isEmpty else {
            return (raw.trimmingCharacters(in: .whitespaces), [])
        }

        var words: [LyricWord] = []
        var text = ""
        var cursor = 0
        for match in matches {
            let segment = nsRaw.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !segment.isEmpty {
                let time = words.last?.time ?? 0
                words.append(LyricWord(time: time, text: segment))
                text += segment
            }
            cursor = match.range.location + match.range.length
            words.append(LyricWord(time: seconds(from: nsRaw, match: match), text: ""))
        }
        let tail = nsRaw.substring(from: cursor)
        if !tail.isEmpty {
            text += tail
            words.append(LyricWord(time: words.last?.time ?? 0, text: tail))
        }

        // 把「时间标记」与后随文本合并成 [{time, text}]
        var merged: [LyricWord] = []
        var pendingTime: Double?
        for word in words {
            if word.text.isEmpty {
                pendingTime = word.time
            } else {
                merged.append(LyricWord(time: pendingTime ?? word.time, text: word.text))
                pendingTime = nil
            }
        }
        return (text.trimmingCharacters(in: .whitespaces), merged)
    }
}

// MARK: - 缓存

final class LyricsCache {

    static let shared = LyricsCache()

    private struct Payload: Codable {
        var title: String
        var artist: String
        var album: String
        var raw: String
        var isSynced: Bool
        var source: String
        var savedAt: Date
        var translations: [Int: String]?
    }

    private let directory: URL
    private var memory: [String: LyricsDocument] = [:]
    private let lock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Lyrascope/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for track: NowPlayingTrack) -> URL {
        let key = "\(track.title)|\(track.artist)|\(track.album)"
        let hash = key.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    func document(for track: NowPlayingTrack) -> LyricsDocument? {
        lock.lock()
        let cached = memory[track.identity]
        lock.unlock()
        if let cached { return cached }

        guard let data = try? Data(contentsOf: fileURL(for: track)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        var document = LRCParser.parse(payload.raw, source: LyricsSource(rawValue: payload.source) ?? .cache)
        document.title = payload.title
        document.artist = payload.artist
        document.album = payload.album
        if let translations = payload.translations {
            document.mergeTranslations(translations)
        }
        lock.lock()
        memory[track.identity] = document
        lock.unlock()
        return document
    }

    static func translationMap(of document: LyricsDocument) -> [Int: String]? {
        var map: [Int: String] = [:]
        for line in document.lines {
            if let translation = line.translation, !translation.isEmpty {
                map[line.id] = translation
            }
        }
        return map.isEmpty ? nil : map
    }

    func store(_ document: LyricsDocument, raw: String, for track: NowPlayingTrack, translations: [Int: String]? = nil) {
        lock.lock()
        memory[track.identity] = document
        lock.unlock()
        let payload = Payload(
            title: track.title,
            artist: track.artist,
            album: track.album,
            raw: raw,
            isSynced: document.isSynced,
            source: document.source.rawValue,
            savedAt: Date(),
            translations: translations ?? Self.translationMap(of: document)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL(for: track), options: .atomic)
    }

    /// 只更新缓存里的翻译，不动原始歌词文本。
    func storeTranslations(_ map: [Int: String], for track: NowPlayingTrack) {
        guard !map.isEmpty else { return }
        if var document = memory[track.identity] {
            document.mergeTranslations(map)
            lock.lock()
            memory[track.identity] = document
            lock.unlock()
        }
        let url = fileURL(for: track)
        guard let data = try? Data(contentsOf: url),
              var payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        var merged = payload.translations ?? [:]
        merged.merge(map) { _, new in new }
        payload.translations = merged
        guard let encoded = try? JSONEncoder().encode(payload) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    func removeAll() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
