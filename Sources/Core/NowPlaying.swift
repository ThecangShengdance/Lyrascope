//
//  NowPlaying.swift
//  Lyrascope
//
//  读取「正在播放」信息。优先使用 MediaRemote 的公开通知/查询函数（私有框架，仅本地运行），
//  失败时自动退回 Music.app 的 AppleScript。
//

import AppKit
import Foundation
import os

// MARK: - 曲目

struct NowPlayingTrack: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var isPlaying: Bool = false
    var artwork: NSImage?
    var source: String = ""

    static let none = NowPlayingTrack()

    var isEmpty: Bool { title.isEmpty }

    /// 用于歌词缓存/匹配的稳定键。
    var identity: String {
        [title, artist, album].joined(separator: "\u{1}")
    }

    var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    static func == (lhs: NowPlayingTrack, rhs: NowPlayingTrack) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && abs(lhs.duration - rhs.duration) < 0.5
            && lhs.isPlaying == rhs.isPlaying
            && lhs.elapsed == rhs.elapsed
    }
}

// MARK: - MediaRemote 桥接

private enum MediaRemoteBridge {
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias RegisterNotifications = @convention(c) () -> Void

    static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }()

    static var getNowPlayingInfo: GetNowPlayingInfo? {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
    }

    static var getIsPlaying: GetIsPlaying? {
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { return nil }
        return unsafeBitCast(symbol, to: GetIsPlaying.self)
    }

    static var isAvailable: Bool { getNowPlayingInfo != nil }

    static let artworkKey = "kMRMediaRemoteNowPlayingInfoArtworkData"
    static let titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artistKey = "kMRMediaRemoteNowPlayingInfoArtist"
    static let albumKey = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let durationKey = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedKey = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let rateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    static let timestampKey = "kMRMediaRemoteNowPlayingInfoTimestamp"
    static let clientBundleKey = "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"
}

// MARK: - 监听器

final class NowPlayingMonitor {

    var onUpdate: ((NowPlayingTrack?) -> Void)?

    private(set) var current: NowPlayingTrack?
    private var timer: Timer?
    /// AppleScript 每次都要起一个辅助进程，很贵：只在 MediaRemote 失手时低频兜底。
    private var lastAppleScriptAttempt: TimeInterval = 0
    private var anchorElapsed: Double = 0
    private var anchorTime: CFTimeInterval = 0
    private var anchorPlaying = false
    private var lastAppleScriptDate: Date = .distantPast
    private var isQuerying = false

    func start() {
        stop()
        if MediaRemoteBridge.isAvailable {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(nowPlayingChanged),
                name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                object: nil
            )
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(nowPlayingChanged),
                name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                object: nil
            )
        }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func nowPlayingChanged() {
        refresh()
    }

    /// 当前估算播放位置（考虑暂停与插值）。
    func estimatedPosition() -> Double {
        guard var track = current else { return 0 }
        var position = anchorElapsed
        if anchorPlaying {
            position += CACurrentMediaTime() - anchorTime
        }
        if track.duration > 0 {
            position = min(position, track.duration)
        }
        track.elapsed = position
        return max(0, position)
    }

    // MARK: 查询

    private func refresh() {
        guard !isQuerying else { return }
        isQuerying = true

        guard let getInfo = MediaRemoteBridge.getNowPlayingInfo else {
            isQuerying = false
            refreshViaAppleScript()
            return
        }

        getInfo(DispatchQueue.main) { [weak self] dictionary in
            guard let self else { return }
            let info = dictionary as? [String: Any]
            self.isQuerying = false
            if let info, let track = self.parse(info: info) {
                self.publish(track)
            } else {
                self.refreshViaAppleScript()
            }
        }
    }

    private func parse(info: [String: Any]) -> NowPlayingTrack? {
        guard let title = info[MediaRemoteBridge.titleKey] as? String, !title.isEmpty else { return nil }

        var track = NowPlayingTrack()
        track.title = title
        track.artist = info[MediaRemoteBridge.artistKey] as? String ?? ""
        track.album = info[MediaRemoteBridge.albumKey] as? String ?? ""
        track.duration = (info[MediaRemoteBridge.durationKey] as? NSNumber)?.doubleValue ?? 0
        track.source = info[MediaRemoteBridge.clientBundleKey] as? String ?? "MediaRemote"

        let rate = (info[MediaRemoteBridge.rateKey] as? NSNumber)?.doubleValue ?? 0
        track.isPlaying = rate > 0

        var elapsed = (info[MediaRemoteBridge.elapsedKey] as? NSNumber)?.doubleValue ?? 0
        if let timestamp = info[MediaRemoteBridge.timestampKey] as? Date, track.isPlaying {
            elapsed += Date().timeIntervalSince(timestamp)
        }
        track.elapsed = max(0, elapsed)

        if let data = info[MediaRemoteBridge.artworkKey] as? Data {
            track.artwork = NSImage(data: data)
        }

        anchorElapsed = track.elapsed
        anchorTime = CACurrentMediaTime()
        anchorPlaying = track.isPlaying
        return track
    }

    private func publish(_ track: NowPlayingTrack) {
        let previous = current
        current = track
        if previous?.identity != track.identity || previous?.isPlaying != track.isPlaying {
            onUpdate?(track)
        } else if abs((previous?.elapsed ?? 0) - track.elapsed) > 1.5 {
            onUpdate?(track)
        }
    }

    // MARK: AppleScript 兜底

    private func refreshViaAppleScript() {
        let now = CACurrentMediaTime()
        guard now - lastAppleScriptAttempt > 8 else { return }
        lastAppleScriptAttempt = now
        // 每 2 秒最多查询一次，避免频繁触发自动化权限提示。
        guard Date().timeIntervalSince(lastAppleScriptDate) > 2 else { return }
        lastAppleScriptDate = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let script = """
            if application "Music" is running then
                tell application "Music"
                    set stateText to (player state as string)
                    if stateText is "stopped" then return ""
                    set trackTitle to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackDuration to duration of current track
                    set trackPosition to player position
                    return trackTitle & linefeed & trackArtist & linefeed & trackAlbum & linefeed & (trackDuration as string) & linefeed & (trackPosition as string) & linefeed & stateText
                end tell
            end if
            return ""
            """
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let output = result.stringValue, !output.isEmpty else {
                DispatchQueue.main.async { self.publishNilIfNeeded() }
                return
            }
            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 6 else { return }

            var track = NowPlayingTrack()
            track.title = parts[0]
            track.artist = parts[1]
            track.album = parts[2]
            track.duration = Double(parts[3].trimmingCharacters(in: .whitespaces)) ?? 0
            track.elapsed = Double(parts[4].trimmingCharacters(in: .whitespaces)) ?? 0
            track.isPlaying = parts[5].contains("playing")
            track.source = "Music.app"

            DispatchQueue.main.async {
                self.anchorElapsed = track.elapsed
                self.anchorTime = CACurrentMediaTime()
                self.anchorPlaying = track.isPlaying
                self.publish(track)
            }
        }
    }

    private func publishNilIfNeeded() {
        if current?.isPlaying == true, estimatedPosition() > 0 { return }
        guard current != nil else { return }
        current = nil
        onUpdate?(nil)
    }
}
