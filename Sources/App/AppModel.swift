//
//  AppModel.swift
//  Lyrascope
//
//  把音频采集、分析、正在播放、歌词、渲染串在一起的中枢。
//  只有主线程会碰这里的可变状态：音频线程只往环形缓冲里写。
//

import AppKit
import Combine
import QuartzCore
import SwiftUI
import ScreenCaptureKit

@MainActor
final class AppModel: ObservableObject {

    static let shared = AppModel()

    let settings: SettingsStore
    let engine = VisualizerEngine()
    let lyrics = LyricsCoordinator()
    let translator = LyricsTranslator()

    let capture = SystemAudioCapture()
    let analyzer = SpectrumAnalyzer()
    let nowPlaying = NowPlayingMonitor()

    @Published private(set) var frame = AudioFrame.empty
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var captureState: AudioCaptureState = .idle
    @Published private(set) var isFullScreen = false
    @Published var banner: String?
    /// 回调在跑但一直听不到声音 → 多半是系统录音权限没生效，界面给一个手动入口。
    @Published private(set) var needsAudioPermission = false
    @Published var isOnboardingPresented = false

    private var ticker: Timer?
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var lastBeat: CFTimeInterval = -10
    private var liveNormalizer: Float = 0.9
    private var lastFramePublish: CFTimeInterval = 0
    private var audioStartedAt: CFTimeInterval = 0
    private var warnedNoCallback = false
    private var silentCallbackSince: CFTimeInterval?
    private var askedCapturePermission = false
    private var silentRestarts = 0
    private var hasEverHeardAudio = false
    private var silentSince: CFTimeInterval?
    private var lastAudioRecovery: CFTimeInterval = 0
    private var lastAudibleTime: CFTimeInterval = 0
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private init() {
        settings = SettingsStore()
    }

    // MARK: - 生命周期

    func start() {
        capture.onOutputDeviceChange = { [weak self] in
            guard let self else { return }
            guard self.settings.captureMode == .systemTap else { return }
            guard self.captureState.isRunning else { return }
            self.recoverAudio(reason: "输出设备变化")
        }
        guard !started else { return }
        started = true

        analyzer.gain = Float(settings.inputGain)
        bindPublishers()
        startAudio()
        startTicking()

        nowPlaying.onUpdate = { [weak self] track in
            MainActor.assumeIsolated { self?.apply(track: track) }
        }
        nowPlaying.start()

        if !settings.hasCompletedOnboarding {
            isOnboardingPresented = true
        }
    }

    func shutdown() {
        ticker?.invalidate()
        ticker = nil
        nowPlaying.stop()
        capture.stop()
    }

    private func bindPublishers() {
        settings.$captureMode
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.capture.stop()
                    self?.startAudio()
                }
            }
            .store(in: &cancellables)

        settings.$inputGain
            .dropFirst()
            .sink { [weak self] gain in
                MainActor.assumeIsolated { self?.analyzer.gain = Float(gain) }
            }
            .store(in: &cancellables)

        settings.$enableLRCLib
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadLyrics() } }
            .store(in: &cancellables)

        settings.$enableAppleMusicLyrics
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadLyrics() } }
            .store(in: &cancellables)

        lyrics.$document
            .compactMap { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.requestTranslationIfNeeded() } }
            .store(in: &cancellables)

        settings.$localLyricsFolder
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadLyrics() } }
            .store(in: &cancellables)
    }

    // MARK: - 音频

    private func startAudio() {
        captureState = .starting
        audioStartedAt = CACurrentMediaTime()
        warnedNoCallback = false
        let analyzer = self.analyzer
        capture.sink = { left, right, frames, sampleRate in
            analyzer.ingest(left: left, right: right, frames: frames, sampleRate: sampleRate)
        }

        let mode = settings.captureMode
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start(mode: mode)
                await MainActor.run {
                    self.captureState = self.capture.state
                    if case .running = self.capture.state { self.banner = nil }
                }
            } catch {
                await MainActor.run {
                    self.captureState = .failed(error.localizedDescription)
                    self.banner = error.localizedDescription
                }
            }
        }
    }

    /// 音频链路健康检查。
    ///
    /// 进程 Tap 挂在聚合设备上，以下两种情况都会让回调「静默停掉」：
    ///   · 默认输出设备变了（插耳机、切 AirPods、切显示器音箱）
    ///   · 聚合设备被系统重建
    /// 此时 `isRunning` 仍是 true、界面照常动（着色器有时间项），
    /// 但频段全是 0——看起来就是「音乐在放，画面却没有频谱」。
    /// 这里在播放中长时间没数据时自动重连一次。
    /// 调试：探测屏幕/系统音频录制权限是否可用。
    func probeCapturePermission() {
        guard ProcessInfo.processInfo.environment["LYRA_DEBUG"] != nil else { return }
        Task {
            do {
                let content = try await SCShareableContent.current
                FileHandle.standardError.write("LYRA sck-ok displays=\(content.displays.count)\n".data(using: .utf8)!)
            } catch {
                FileHandle.standardError.write("LYRA sck-error \(error)\n".data(using: .utf8)!)
            }
        }
    }

    private func auditAudioPipeline(_ frame: AudioFrame, now: CFTimeInterval) {
        let callbacksAlive = capture.secondsSinceLastCallback() < 1.0
        // 注意：不能用 frame.isSilent 判断「有没有真的听到声音」——
        // 它的判定带 0.8 秒滞回，启动瞬间一定是 false。这里直接看电平。
        let frameHasAudio = frame.peak > 0.0008 || frame.level > 0.0008
        if frameHasAudio {
            hasEverHeardAudio = true
            needsAudioPermission = false
            silentCallbackSince = nil
            silentRestarts = 0
        } else if callbacksAlive {
            // 回调在跑却一直是 0：先自己重连两次（有可能是权限刚被授予、
            // 或者聚合设备状态没刷新），仍然没声音再去请求系统授权。
            if silentCallbackSince == nil { silentCallbackSince = now }
            let quietFor = now - (silentCallbackSince ?? now)
            if quietFor > 4, !hasEverHeardAudio {
                // 安静地自己重连：用户在系统设置里勾上权限后，不用重启 App。
                if now - lastAudioRecovery > 4, silentRestarts < 40 {
                    silentRestarts += 1
                    silentCallbackSince = nil
                    lastAudioRecovery = now
                    recoverAudio(reason: "启动后一直没有声音")
                }
                // 连试 3 次仍完全没声音，才在界面上给一个「去授权」的小按钮，
                // 不主动弹窗、不自动打开设置面板。
                if silentRestarts >= 3 { needsAudioPermission = true }
            } else {
                needsAudioPermission = false
            }
        }

        if frame.isSilent {
            if silentSince == nil { silentSince = now }
        } else {
            silentSince = nil
            lastAudibleTime = now
        }

        guard captureState.isRunning else { return }

        // 启动后一直收不到任何音频：大概率是权限或采集方式不支持，
        // 直接给出可执行的提示，而不是让画面静静地没反应。
        if !warnedNoCallback, now - audioStartedAt > 5, capture.secondsSinceLastCallback() > 5 {
            warnedNoCallback = true
            banner = settings.captureMode == .screenCapture
                ? "屏幕录制音频没有收到数据，请在设置里把采集方式切回 Core Audio Tap"
                : "没有收到系统音频，请在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 中允许 Lyrascope"
        }

        if warnedNoCallback, capture.secondsSinceLastCallback() < 1.0 {
            warnedNoCallback = false
            banner = nil
        }

        let stalled = capture.secondsSinceLastCallback() > 2.0
        let silentTooLong = silentSince.map { now - $0 > 3.0 } ?? false
        // 只在播放器明确处于「播放中」时才判断，避免暂停、静音时反复重连。
        guard track?.isPlaying == true else { return }
        guard stalled || silentTooLong else { return }
        guard now - lastAudioRecovery > 8 else { return }

        lastAudioRecovery = now
        silentSince = nil
        recoverAudio(reason: stalled ? "音频回调中断" : "没有收到声音")
    }

    /// 由界面按钮调用：打开系统设置的录音权限面板，并顺手请求一次授权。
    func openPrivacySettings() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func recoverAudio(reason: String) {
        if ProcessInfo.processInfo.environment["LYRA_DEBUG"] != nil {
            FileHandle.standardError.write("LYRA audio-recover: \(reason)\n".data(using: .utf8)!)
        }
        capture.stop()
        startAudio()
        banner = "正在重新连接系统音频（\(reason)）…"
    }

    func retryAudio() {
        capture.stop()
        startAudio()
    }

    // MARK: - 帧循环

    private func startTicking() {
        // 30 Hz 已经足够：FFT 窗口是 4096 帧，30 fps 的帧间隔正好 1600 个新采样。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = max(0.0001, now - lastTick)
        lastTick = now

        // 没有在采集时不必反复对零做 FFT，画面靠上一帧与时间继续动。
        if captureState.isRunning {
            analyzer.tick(deltaTime: delta)
        }
        let current = analyzer.snapshot()

        if current.beat > 0.55, now - lastBeat > 0.22 {
            lastBeat = now
        }

        // 频段对比度：拿「中位数」当地板、最响频段当顶，把大多数频段压回中低段，
        // 只留真正的峰值顶上去；再和原始值混一半，避免噪声型素材整屏发黑。
        auditAudioPipeline(current, now: now)

        let display = Self.enhanceContrast(of: current)
        liveNormalizer = 1.0

        engine.update(
            frame: display,
            config: visualConfig,
            beatAge: Float(max(0, now - lastBeat))
        )

        // SwiftUI 侧不需要 120Hz，20Hz 足够显示数值与歌词。
        if now - lastFramePublish > 1.0 / 15.0 {
            lastFramePublish = now
            frame = display
            debugTick(current)
            lyrics.update(position: nowPlaying.estimatedPosition(), offset: settings.lyricsOffset)
        }
    }

    // MARK: - 歌词翻译

    private var translatedIdentities = Set<String>()

    /// 同步歌词、没有自带翻译、且用户开着「自动翻译」时，用系统翻译框架补一遍。
    private func requestTranslationIfNeeded() {
        guard settings.showTranslation, settings.autoTranslate else { return }
        guard let document = lyrics.document,
              document.isSynced,
              !document.hasTranslations,
              document.lines.count > 0,
              let track = lyrics.resolvedTrack else { return }
        guard !translatedIdentities.contains(track.identity) else { return }

        let joined = document.lines.map(\.text).joined(separator: "\n")
        let target = LyricsTranslator.targetLanguageIdentifier
        guard !LyricsTranslator.isAlreadyTargetLanguage(joined, target: target) else {
            translatedIdentities.insert(track.identity)
            return
        }
        translatedIdentities.insert(track.identity)

        let texts = document.lines.map(\.text)
        let ids = document.lines.map(\.id)
        translator.submit(texts: texts) { [weak self] results in
            guard let self, results.count == texts.count else { return }
            var map: [Int: String] = [:]
            for (offset, text) in results.enumerated() {
                let original = texts[offset]
                guard !text.isEmpty, text != original else { continue }
                map[ids[offset]] = text
            }
            guard !map.isEmpty else { return }
            self.lyrics.applyTranslations(map)
            LyricsCache.shared.storeTranslations(map, for: track)
        }
    }

    /// 把频段从「都挤在中段」拉开：以中位数为地板、最大值为顶做一次白化，
    /// 再按 45% 的原值融合，既有起伏又不会让噪声型素材变成一片黑。
    private static func enhanceContrast(of frame: AudioFrame) -> AudioFrame {
        var result = frame
        guard !frame.bands.isEmpty else { return result }

        let sorted = frame.bands.sorted()
        let median = sorted[sorted.count / 2]
        let peak = sorted.last ?? median
        guard peak > 0.05 else { return result }

        let floor = min(0.55, median * 0.92)
        let span = max(0.22, peak - floor)
        var bands = [Float](repeating: 0, count: frame.bands.count)
        var peaks = bands
        for index in 0..<frame.bands.count {
            let raw = frame.bands[index]
            let whitened = max(0, min(1, (raw - floor) / span))
            bands[index] = min(1, (raw * 0.45 + whitened * 0.55)) * 1.04
            let rawPeak = index < frame.peaks.count ? frame.peaks[index] : raw
            let whitenedPeak = max(0, min(1, (rawPeak - floor) / span))
            peaks[index] = min(1, (rawPeak * 0.50 + whitenedPeak * 0.50)) * 1.04
        }
        result.bands = bands
        result.peaks = peaks
        return result
    }

    private var perfWall: Double = 0
    private var perfCPU: Double = 0

    /// 顺便报一下自己的 CPU 占用，调性能时不用再开活动监视器。
    private func debugPerformance() {
        guard ProcessInfo.processInfo.environment["LYRA_DEBUG"] != nil else { return }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = CACurrentMediaTime()
        guard perfWall > 0 else {
            perfWall = wall
            perfCPU = cpu
            return
        }
        let span = wall - perfWall
        guard span > 1.5 else { return }
        let percent = (cpu - perfCPU) / span * 100
        FileHandle.standardError.write(Data(String(format: "LYRA cpu=%.1f%%\n", percent).utf8))
        perfWall = wall
        perfCPU = cpu
    }

    /// `LYRA_DEBUG=1` 时每秒往 stderr 打一行采集诊断，方便排查系统录音是否真的有声音。
    private var debugCounter = 0
    private func appendDebugLog(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/lyra-debug.log")
        let text = String(format: "%.0f ", Date().timeIntervalSince1970) + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func debugTick(_ frame: AudioFrame) {
        guard ProcessInfo.processInfo.environment["LYRA_DEBUG"] != nil else { return }
        debugCounter += 1
        debugPerformance()
        guard debugCounter % 15 == 0 else { return }
        let peakBand = frame.bands.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
        FileHandle.standardError.write(Data(String(
            format: "LYRA level=%.3f bass=%.3f peak=%.3f lufs=%.1f band#%d=%.2f silent=%@ cbAge=%.2f running=%@\n",
            frame.level, frame.bass, frame.peak, frame.loudness, peakBand,
            peakBand >= 0 ? frame.bands[peakBand] : 0,
            frame.isSilent ? "yes" : "no",
            min(999.0, capture.secondsSinceLastCallback()),
            captureState.isRunning ? "yes" : "no"
        ).utf8))
        FileHandle.standardError.write(Data("LYRA io=\(capture.ioCallCount) fmt=\(capture.lastFormatNote)\n".utf8))
        appendDebugLog("level=\(frame.level) io=\(capture.ioCallCount) cbAge=\(capture.secondsSinceLastCallback())")
    }

    /// 没有声音时没必要按 60 fps 重画整屏，自动降到 30 fps 省电。
    var effectiveFPS: Int {
        guard settings.renderFPS > 30 else { return 30 }
        let idle = frame.isSilent && track?.isPlaying != true
        return idle ? 30 : settings.renderFPS
    }

    var visualConfig: VisualConfig {
        var config = VisualConfig()
        config.mode = settings.visualMode.shaderIndex
        config.palette = paletteIndex
        config.bloom = Float(settings.bloom)
        config.normalizer = liveNormalizer
        config.dim = Float(settings.backgroundDim * 0.22)
        return config
    }

    private var paletteIndex: Int {
        switch settings.lyricsAccent {
        case .aurora: return 0
        case .gold: return 1
        case .ice: return 2
        case .mono: return 3
        }
    }

    // MARK: - 播放信息

    private func apply(track newTrack: NowPlayingTrack?) {
        let changed = newTrack?.identity != track?.identity
        track = newTrack

        if changed {
            lyrics.load(track: newTrack, options: resolverOptions)
        } else if newTrack == nil {
            lyrics.load(track: nil, options: resolverOptions)
        }
    }

    private var resolverOptions: LyricsResolverOptions {
        LyricsResolverOptions(
            enableLRCLib: settings.enableLRCLib,
            enableAppleMusic: settings.enableAppleMusicLyrics,
            localFolder: settings.localLyricsFolder
        )
    }

    func reloadLyrics() {
        lyrics.load(track: track, options: resolverOptions)
    }

    // MARK: - 便捷操作

    func toggleVisualMode() {
        let all = VisualMode.allCases
        guard let index = all.firstIndex(of: settings.visualMode) else { return }
        withAnimation(.snappy(duration: 0.3)) {
            settings.visualMode = all[(index + 1) % all.count]
        }
    }

    func selectVisualMode(_ mode: VisualMode) {
        withAnimation(.snappy(duration: 0.3)) { settings.visualMode = mode }
    }

    func toggleLyrics() {
        settings.showDesktopLyrics.toggle()
        WindowManager.shared.updateLyricsVisibility()
    }

    func cycleAccent() {
        let all = AccentStyle.allCases
        guard let index = all.firstIndex(of: settings.lyricsAccent) else { return }
        settings.lyricsAccent = all[(index + 1) % all.count]
    }

    func setFullScreen(_ value: Bool) {
        isFullScreen = value
    }

    func toggleFullScreen() {
        guard let window = WindowManager.shared.mainWindow else { return }
        window.toggleFullScreen(nil)
    }

    /// 只表示“现在听不到声音”。播放器元数据缺失不该算静音——那是两件事。
    var isSilent: Bool {
        frame.isSilent
    }

    var statusText: String {
        if case let .failed(message) = captureState { return message }
        if case .starting = captureState { return "正在连接系统音频…" }
        if !captureState.isRunning { return "音频未启动" }
        if track == nil { return "等待播放器" }
        return "正在聆听"
    }
}
