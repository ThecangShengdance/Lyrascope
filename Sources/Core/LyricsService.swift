//
//  LyricsService.swift
//  Lyrascope
//
//  歌词获取管线：
//    1. 本地 .lrc 文件夹
//    2. 本地缓存
//    3. Apple Music（仅本地歌曲才有 lyrics 属性）
//    4. LRCLIB 公开 API（社区歌词库，无需 API key）
//

import AppKit
import Foundation

// MARK: - 解析选项

struct LyricsResolverOptions {
    var enableLRCLib: Bool
    var enableAppleMusic: Bool
    var localFolder: String
}

// MARK: - LRCLIB 客户端

struct LRCLibTrack: Decodable {
    var id: Int?
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}

final class LRCLibClient {

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Lyrascope/1.0 (macOS; local app)",
            "Accept": "application/json"
        ]
        return URLSession(configuration: configuration)
    }()

    private var baseURL: URL { URL(string: "https://lrclib.net/api")! }

    func fetch(track: NowPlayingTrack) async -> (raw: String, synced: Bool)? {
        if let exact = await get(track: track), let result = makeResult(exact) {
            return result
        }
        if let searched = await search(track: track), let result = makeResult(searched) {
            return result
        }
        return nil
    }

    private func makeResult(_ track: LRCLibTrack) -> (raw: String, synced: Bool)? {
        if track.instrumental == true { return nil }
        if let synced = track.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (synced, true)
        }
        if let plain = track.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (plain, false)
        }
        return nil
    }

    private func get(track: NowPlayingTrack) async -> LRCLibTrack? {
        var components = URLComponents(url: baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 1 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        return await request(url)
    }

    private func search(track: NowPlayingTrack) async -> LRCLibTrack? {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        let query = "\(cleanTitle(track.title)) \(track.artist)"
            .trimmingCharacters(in: .whitespaces)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return nil }
        guard let list = await requestList(url), !list.isEmpty else { return nil }
        if let synced = list.first(where: { ($0.syncedLyrics?.isEmpty == false) }) {
            return synced
        }
        return list.first
    }

    private func request(_ url: URL) async -> LRCLibTrack? {
        guard let data = await load(url) else { return nil }
        return try? JSONDecoder().decode(LRCLibTrack.self, from: data)
    }

    private func requestList(_ url: URL) async -> [LRCLibTrack]? {
        guard let data = await load(url) else { return nil }
        return try? JSONDecoder().decode([LRCLibTrack].self, from: data)
    }

    private func load(_ url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// 去掉 "(Remastered)"、"feat." 之类的尾巴，提高搜索命中率。
    private func cleanTitle(_ title: String) -> String {
        var result = title
        let patterns = [
            #"\s*[\(\[]\s*(feat|ft|with)\..*?[\)\]]"#,
            #"\s*[\(\[]\s*(remaster(ed)?|live|deluxe|explicit|radio edit|version).*?[\)\]]"#,
            #"\s*-\s*(remaster(ed)?|live|deluxe).*$"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 解析器

final class LyricsResolver {

    private let client = LRCLibClient()
    private let queue = DispatchQueue(label: "com.zhangzhouqi.Lyrascope.lyrics", qos: .userInitiated)
    private var lastMiss: [String: Date] = [:]
    private var negativeLock = NSLock()

    func resolve(track: NowPlayingTrack, options: LyricsResolverOptions) async -> LyricsDocument? {
        guard !track.title.isEmpty else { return nil }

        let key = track.identity
        if let missDate = negativeLock.withLock({ lastMiss[key] }),
           Date().timeIntervalSince(missDate) < 600 {
            return nil
        }

        // 纯文本（没有时间轴）不是最优解：先留着，继续找带时间轴的版本。
        var fallback: (document: LyricsDocument, raw: String)?

        func accept(_ document: LyricsDocument, raw: String) -> LyricsDocument? {
            guard !document.lines.isEmpty else { return nil }
            if document.isSynced { return document }
            if fallback == nil { fallback = (document, raw) }
            return nil
        }

        if let local = localLyrics(for: track, folder: options.localFolder),
           let synced = accept(local.document, raw: local.raw) {
            LyricsCache.shared.store(synced, raw: local.raw, for: track)
            return synced
        }

        if let cached = LyricsCache.shared.document(for: track),
           let synced = accept(cached, raw: "") {
            return synced
        }

        // LRCLIB 是同步歌词的主力来源，放在 Apple Music 的纯文本之前。
        if options.enableLRCLib, let result = await client.fetch(track: track) {
            var document = LRCParser.parse(result.raw, source: .lrclib)
            document.title = track.title
            document.artist = track.artist
            document.album = track.album
            document.isSynced = result.synced && document.isSynced
            if let synced = accept(document, raw: result.raw) {
                LyricsCache.shared.store(synced, raw: result.raw, for: track)
                return synced
            }
        }

        if options.enableAppleMusic, let raw = await appleMusicLyrics(),
           let document = document(from: raw, track: track),
           let synced = accept(document, raw: raw) {
            LyricsCache.shared.store(synced, raw: raw, for: track)
            return synced
        }

        // 只有纯文本时，按曲长估一个时间轴，至少能跟着音乐往下走。
        if var plain = fallback?.document {
            let raw = fallback?.raw ?? ""
            plain.applyEstimatedTiming(duration: track.duration)
            LyricsCache.shared.store(plain, raw: raw, for: track)
            return plain
        }

        negativeLock.withLock { lastMiss[key] = Date() }
        return nil
    }

    private func document(from raw: String, track: NowPlayingTrack) -> LyricsDocument? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var document = LRCParser.parse(trimmed, source: .appleMusic)
        document.title = track.title
        document.artist = track.artist
        document.album = track.album
        return document
    }

    // MARK: 本地 LRC

    private func localLyrics(for track: NowPlayingTrack, folder: String) -> (document: LyricsDocument, raw: String)? {
        guard !folder.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        let needleTitle = Self.normalize(track.title)
        let needleArtist = Self.normalize(track.artist)
        guard !needleTitle.isEmpty else { return nil }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var best: URL?
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 4000 { break }
            guard url.pathExtension.lowercased() == "lrc" else { continue }
            let name = Self.normalize(url.deletingPathExtension().lastPathComponent)
            if name.contains(needleTitle) {
                if !needleArtist.isEmpty, name.contains(needleArtist) {
                    best = url
                    break
                }
                if best == nil { best = url }
            }
        }

        guard let url = best, let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var document = LRCParser.parse(raw, source: .localFile)
        document.title = track.title
        document.artist = track.artist
        mergeSiblingTranslation(into: &document, for: url)
        return (document, raw)
    }

    /// 同一个文件夹里如果有 `歌名.trans.lrc` / `歌名.zh.lrc` / `歌名.translation.lrc`，
    /// 就按时间戳把它们并成翻译行；没有时间轴时按行号对齐。
    private func mergeSiblingTranslation(into document: inout LyricsDocument, for url: URL) {
        let base = url.deletingPathExtension()
        let candidates = [
            base.appendingPathExtension("trans").appendingPathExtension("lrc"),
            base.appendingPathExtension("zh").appendingPathExtension("lrc"),
            base.appendingPathExtension("cn").appendingPathExtension("lrc"),
            base.appendingPathExtension("translation").appendingPathExtension("lrc")
        ]
        guard let translationURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let raw = try? String(contentsOf: translationURL, encoding: .utf8) else { return }

        let translation = LRCParser.parse(raw, source: .localFile)
        guard !translation.lines.isEmpty else { return }

        if translation.isSynced {
            var map: [Int: String] = [:]
            for line in document.lines {
                let best = translation.lines.min(by: { abs($0.time - line.time) < abs($1.time - line.time) })
                guard let best, abs(best.time - line.time) < 0.4, !best.text.isEmpty else { continue }
                map[line.id] = best.text
            }
            document.mergeTranslations(map)
        } else if translation.lines.count >= document.lines.count {
            var map: [Int: String] = [:]
            for index in document.lines.indices {
                map[document.lines[index].id] = translation.lines[index].text
            }
            document.mergeTranslations(map)
        }
    }

    private static func normalize(_ string: String) -> String {
        string
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
    }

    // MARK: Apple Music

    /// Music.app 的 `lyrics` 属性只有本地文件才有内容；
    /// Apple Music 流媒体歌曲的歌词是加密 TTML，系统没有公开接口。
    private func appleMusicLyrics() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                let script = """
                if application "Music" is running then
                    tell application "Music"
                        try
                            set currentLyrics to lyrics of current track
                            if currentLyrics is missing value then return ""
                            return currentLyrics
                        on error
                            return ""
                        end try
                    end tell
                end if
                return ""
                """
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(returning: nil)
                    return
                }
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                guard error == nil, let text = result.stringValue, !text.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }
}

// MARK: - 协调器

@MainActor
final class LyricsCoordinator: ObservableObject {

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case unsynced
        case missing(String)

        var isReady: Bool { self == .ready || self == .unsynced }
    }

    @Published private(set) var document: LyricsDocument?
    @Published private(set) var status: Status = .idle
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentText: String = ""
    @Published private(set) var nextText: String = ""
    @Published private(set) var translationText: String = ""
    @Published private(set) var resolvedTrack: NowPlayingTrack?

    /// 手动偏移（秒），和设置里的偏移叠加。
    var extraOffset: Double = 0

    private let resolver = LyricsResolver()
    private var loadTask: Task<Void, Never>?
    private var pendingTrack: NowPlayingTrack?

    var hasLyrics: Bool { document?.isEmpty == false }

    func load(track: NowPlayingTrack?, options: LyricsResolverOptions) {
        loadTask?.cancel()

        guard let track, !track.title.isEmpty else {
            document = nil
            status = .idle
            currentIndex = -1
            currentText = ""
            nextText = ""
            translationText = ""
            resolvedTrack = nil
            return
        }

        if pendingTrack?.identity == track.identity, status.isReady { return }
        pendingTrack = track
        resolvedTrack = track
        status = .loading
        currentIndex = -1
        currentText = ""
        nextText = ""
        translationText = ""

        loadTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolver.resolve(track: track, options: options)
            if Task.isCancelled { return }
            guard let resolved else {
                self.document = nil
                self.status = .missing("没有找到歌词")
                return
            }
            self.document = resolved
            self.status = resolved.isSynced ? .ready : .unsynced
            self.update(position: 0, offset: 0)
        }
    }

    /// 把系统翻译的结果并进当前文档，并立刻刷新当前行。
    func applyTranslations(_ map: [Int: String]) {
        guard !map.isEmpty, var document else { return }
        document.mergeTranslations(map)
        self.document = document
        if currentIndex >= 0, currentIndex < document.lines.count {
            translationText = document.lines[currentIndex].translation ?? ""
        }
    }

    func update(position: Double, offset: Double) {
        guard let document, document.isSynced, !document.lines.isEmpty else {
            if document?.isSynced == false {
                // 纯文本歌词没有时间轴，交给界面整段滚动展示。
                if currentText != document?.lines.first?.text {
                    currentText = document?.lines.first?.text ?? ""
                }
            }
            return
        }

        let time = position + offset + extraOffset
        let index = document.index(at: time)
        if index != currentIndex {
            currentIndex = index
            currentText = index >= 0 ? document.lines[index].text : ""
            nextText = index + 1 < document.lines.count ? document.lines[index + 1].text : ""
            translationText = index >= 0 ? (document.lines[index].translation ?? "") : ""
        }

        if index >= 0 {
            let start = document.lines[index].time
            let end = document.endTime(of: index)
            let span = max(0.001, end - start)
            let value = max(0, min(1, (time - start) / span))
            if abs(value - progress) > 0.005 {
                progress = value
            }
        } else {
            progress = 0
        }
    }
}
