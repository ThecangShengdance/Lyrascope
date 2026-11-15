# 架构说明

Lyrascope 是一个单进程的 macOS App。除了 SwiftUI 界面，它由四条独立但互相供血的管线组成：**采集 → 分析 → 渲染**、**正在播放**、**歌词**、**窗口/形态**。

```
                 ┌──────────────────────────────────────────┐
 系统混音 ──Tap──▶│ SystemAudioCapture  (Core Audio IOProc)  │
                 └───────────────┬──────────────────────────┘
                                 │ Float32 交错/非交错
                                 ▼
                 ┌──────────────────────────────────────────┐
                 │ StereoRingBuffer  (os_unfair_lock)       │
                 └───────────────┬──────────────────────────┘
                                 │ 主线程 60 Hz 取帧
                                 ▼
                 ┌──────────────────────────────────────────┐
                 │ SpectrumAnalyzer                         │
                 │ vDSP FFT·96 对数频段·K 加权 LUFS·节拍    │
                 └───────┬──────────────────────┬───────────┘
                         │ AudioFrame           │ AudioFrame(20 Hz)
                         ▼                      ▼
        ┌────────────────────────┐   ┌─────────────────────────┐
        │ VisualizerEngine       │   │ SwiftUI（歌词/HUD/菜单栏）│
        │ → MetalRenderer 120 Hz │   └─────────────────────────┘
        └────────────────────────┘
```

## 1. 采集：Core Audio 进程 Tap

`Sources/Core/AudioCapture.swift`

- 首选 **进程 Tap**（macOS 14.2+）：`CATapDescription(stereoGlobalTapButExcludeProcesses:)` 描述一个「除自己以外所有进程」的全局立体声 Tap；`AudioHardwareCreateProcessTap` 建 Tap，`AudioHardwareCreateAggregateDevice` 把 Tap 包成一个私有聚合设备，`AudioDeviceCreateIOProcIDWithBlock` 拉 IOProc，`AudioDeviceStart` 开始出数据。
- 排除自身进程是关键：否则可视化画面自己播放的音效（如果有）会反馈进分析。
- `muteBehavior = .unmuted`：Tap 只旁听，不改变用户听到的声音。
- 备选 **ScreenCaptureKit**（`CaptureMode.screenCapture`）：`SCStream` 只采音频、视频给 32×32 的最小流，用于 Tap 无法建立的场景（例如某些虚拟机）。
- IOProc 在实时线程里只做一件事：把 float32 数据交给 `sink` 闭包，闭包再写进 `StereoRingBuffer`。实时线程不加锁、不分配内存。
- 交错与非交错两种 `AudioBufferList` 布局分别处理；非交错时左右声道指针直接传入，交错时先拆到 scratch 缓冲。

失败会带中文原因（`AudioCaptureError`）抛给界面，界面显示「没能听到系统音频」+ 重试按钮。

### 链路自愈

进程 Tap 挂在私有聚合设备上，有两种情况会让 IOProc **静默停掉**：默认输出设备变化（插耳机、切 AirPods、切显示器音箱），或聚合设备被系统重建。此时 `isRunning` 依旧是 `true`、着色器照常走时间项，画面不会「卡住」，但频段全是 0——看起来就像「音乐在放，却没有频谱」。

`SystemAudioCapture` 因此维护 `lastCallbackTime`（每次回调打点）与 `secondsSinceLastCallback()`，并注册 `kAudioHardwarePropertyDefaultOutputDevice` 的属性监听。`AppModel.auditAudioPipeline(_:now:)` 在每次 tick 检查：播放器处于播放中、且回调停止超过 2 s 或静音超过 3 s 时，节流 8 s 重连一次（`capture.stop()` + `startAudio()`），并在界面顶部提示「正在重新连接系统音频」。暂停或纯静音时不会触发，避免无谓重连。

## 2. 分析：一次 FFT 喂饱所有画面

`Sources/Core/AudioAnalyzer.swift`

- 环形缓冲 65 536 帧（约 1.36 s @48 kHz），每次 tick 取 4096 帧做一帧 FFT。
- 4096 点 Hann 窗，`vDSP_ctoz` → `vDSP_fft_zrip` → `vDSP_zvabs`；缩放 `4 / fftSize` 抵消 zrip 的 2 倍与窗的相干增益。
- 96 个对数频段覆盖 25 Hz – 19 kHz，频段边界在初始化时按采样率算好；频段值取区间内最大 dB，映射到 0…1：

  ```
  linear = clamp((dBFS + 80) / 80)
  target = pow(linear, 1.6)
  ```

  再用 attack 18 ms / release 150 ms 的单极平滑，峰值帽按 0.45/s 衰减。这样响度大的曲子不会所有柱子一起顶格，安静的段落也不会被抬成噪声。
- 响度：K 加权（BS.1770 的两级滤波器系数以 48 kHz 计算）后求均方，`LUFS = -0.691 + 10 log10(meanSquare)`。
- 节拍：频谱通量（只累计正向差值）过 `mean + 1.4·std + 0.002` 阈值，最小间隔 0.18 s，得到一个 0…1 的衰减脉冲。
- 波形 256 点、声像 192 个 `SIMD2`、立体声相关系数、频谱质心都在同一次 tick 里算完。

`AudioFrame` 是唯一的交换格式，值类型，拷贝便宜。

## 3. 渲染：运行时编译的 Metal，加上 SwiftUI 兜底

`Sources/Visuals/ShaderSource.swift` + `MetalVisualizer.swift`

- 着色器源码**以字符串形式内嵌**，App 启动时用 `MTLDevice.makeLibrary(source:options:)` 编译。原因有两个：Xcode 26 起 Metal 离线编译器（`metal` 工具链）需要单独下载，仓库里放 `.metal` 会让 CI 或干净环境构建失败；内嵌字符串还能在 `--selftest` 里直接编译一遍验证语法。
- 一个全屏三角形 + 一个 fragment 入口 `fs_composite`，按 `u[U_MODE]` 分派到 `renderAurora` 或 `renderStudio`。
- uniform 是一块 864 个 float 的 `constant float *`（float 下标布局，见表格），避免结构体对齐带来的跨平台坑。
- 帧缓冲格式 `.bgra8Unorm_srgb`：着色器输出线性颜色，硬件负责线性 → sRGB，画面不会二次提亮。
- 五个视图共用同一次 uniform 上传（864 个 float），`mode` 字段分派到 `renderAurora` / `renderStudio` / `renderPrism` / `renderRipple` / `renderRidge`。
- 制作人视图的瀑布图用一张 128×96 的 `r16Float` 纹理做环形历史：每帧把每行左移一列、写入最新频段值，fragment 采样时按 `uv.x + scroll` 取时间轴。
- 没有 Metal 设备时退回 `FallbackVisualizer`（SwiftUI `Canvas` 画径向柱），功能不缺席、只是朴素。

### uniform 布局（float 下标）

| 下标 | 含义 |
| --- | --- |
| 0 / 1 | 时间 / 帧间隔 |
| 2 / 3 | 画布宽 / 高 |
| 4 / 5 / 6 / 7 | bass / mid / treble / level |
| 8 / 9 / 10 | LUFS / 节拍脉冲 / 频谱质心 |
| 11 / 12 / 13 | 峰值 / 立体声相关 / 是否静音 |
| 14 / 15 / 16 / 17 | 视图模式 / 光晕 / 背景压暗 / 频段归一化系数 |
| 18 / 19 / 20 / 21 | 调色板 / 瀑布滚动 / 节拍年龄 / 宽高比 |
| 32–127 | 96 个频段值 |
| 128–223 | 96 个峰值 |
| 224–479 | 256 点波形 |
| 480–863 | 192 个声像点（x, y 交替） |

## 4. 正在播放

`Sources/Core/NowPlaying.swift`

- 通过 `dlopen` 加载私有框架 `MediaRemote`，用 `MRMediaRemoteGetNowPlayingInfo` 拿标题、艺人、专辑、时长、速率、时间戳、封面。
- 每秒轮询 + 订阅 `kMRMediaRemoteNowPlayingInfoDidChangeNotification` 分布式通知。
- 播放位置用 `CACurrentMediaTime()` 在两次轮询之间插值，歌词才能平滑推进。
- MediaRemote 不可用时退回 Music.app 的 AppleScript（`player state` / `player position` / `current track`）。

> MediaRemote 是私有 API。它不会让 App 无法上架（这类读取在很多 App 里都有），但属于「随时可能被系统改掉」的依赖，所以保留 AppleScript 后备路径。若你打算上架 App Store，建议先评估这条风险。

## 5. 歌词

`Sources/Core/Lyrics.swift` + `LyricsService.swift`

解析：

- `LRCParser` 用 `NSRegularExpression` 解析 `[mm:ss.xx]` 行时间、`<mm:ss.xx>` 逐字时间、`[ti:]/[ar:]/[al:]/[offset:]` 元数据。同一时间戳出现多行时，第二行当作翻译；完全没有时间戳则判定为 `isSynced == false`，只滚动展示。
- `LyricsDocument` 提供 `index(at:)`（二分）与 `endTime(of:)`。

解析顺序（命中即停，未命中做 600 s 负缓存）：

1. 用户指定的本地 `.lrc` 目录（最多枚举 4000 个文件，按文件名规范化匹配；同目录下的 `.trans.lrc` 会合并为翻译）
2. 本地缓存 `~/Library/Application Support/Lyrascope/Lyrics/<hash>.json`
3. LRCLIB（`/api/get` 精确查，失败再 `/search` 取第一条带同步歌词的）
4. Music.app 当前曲目的内嵌歌词（只对本地文件有效）

只有「无时间轴的纯文本」时，不会直接展示：先继续找同步版本，全都找不到才用 `applyEstimatedTiming(duration:)` 按曲长铺一条估算时间轴（`isSynced = true, isEstimated = true`），主界面标注「时间轴按曲长估算」。

翻译：歌词自带翻译行就合并；否则（设置里「自动翻译」开启时）用系统 `Translation` 框架在本机翻译，结果写进 `LyricsDocument` 与本地缓存，`TranslationSession` 由挂在 `RootView` 上的 `.translationTask` 驱动。

`LyricsCoordinator` 是 `@MainActor ObservableObject`，持有当前文档、当前行、逐字进度、翻译与下一行，供主界面、桌面歌词、菜单栏三处共用。

## 6. 窗口与形态

`Sources/App/WindowManager.swift`

- 主窗口：`NSWindow` + `NSHostingView`，`.fullSizeContentView`、透明标题栏、`setFrameAutosaveName`。全屏由系统 `toggleFullScreen` 处理，收到 `NSWindow.didEnterFullScreenNotification` 后通知界面隐藏控件。
- 桌面歌词：`NSPanel`（borderless、nonactivating、`.floating` 层级、`.canJoinAllSpaces + .fullScreenAuxiliary`），`isMovableByWindowBackground`，位置写回 `settings.lyricsPanelFrame`；`ignoresMouseEvents` 对应「鼠标穿透」。没有歌词也没有曲目时自动隐藏，不会在桌面下方留一块空面板。
- 菜单栏：`NSStatusItem` 自绘 4 根柱子的高度，随频谱跳动；左键 `NSPopover` 显示面板，右键弹出菜单。
- 「仅菜单栏」用 `NSApp.setActivationPolicy(.accessory)` + 隐藏主窗口。

## 7. 设置与状态

`Sources/Core/Settings.swift`

- 单一的 `SettingsStore`（`@MainActor ObservableObject`），所有属性 `didSet` 立刻写入 `UserDefaults` 的 `Lyrascope.settings.v1`（一个 JSON `Data`）。
- 加载期间用 `isLoading` 抑制 `didSet`，避免启动时把默认值反写。

## 8. 自检与调试

- `Lyrascope --selftest`：不启动界面，跑 13 项断言（LRC 解析、时间索引、频段峰值位置、K 加权响度、相关度、波形/声像非零、Metal 运行时编译），以退出码表示结果。
- 环境变量 `LYRA_DEBUG=1` 时，每秒往 stderr 打一行采集诊断（level / bass / peak / LUFS / 最响频段 / 是否静音），用于排查「有没有真的听到声音」。

## 9. 线程模型

| 线程 | 做什么 |
| --- | --- |
| Core Audio 实时线程 | 只把音频搬进环形缓冲 |
| 主线程（30 Hz Timer） | 分析、更新引擎、15 Hz 发布给 SwiftUI、推进歌词 |
| Metal 渲染线程（MTKView） | 读 `VisualizerEngine` 的帧快照并绘制 |
| 渲染节拍器（主线程 Timer） | 按设置的目标帧率调用 `MTKView.draw()`；不依赖系统的 display link，窗口关闭再打开后仍照常绘制 |
| 后台 Task | 歌词网络请求、本地文件枚举（结果回到 `@MainActor`） |

`StereoRingBuffer` 与 `LyricsCache` 的内部字典用 `os_unfair_lock` / `NSLock` 保护，跨线程访问不裸奔。
