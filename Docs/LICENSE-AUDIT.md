# 许可与侵权审查报告

审查对象：`Lyrascope`（词镜）全部本地代码、资源与工程配置。
审查日期：2026-11-15。
审查方式：全量静态检索 + 依赖清单核对 + 资源来源回溯 + 名称检索。

---

## 一、结论

| 项目 | 结论 |
| --- | --- |
| 是否引入 GPL / AGPL / LGPL 代码 | **没有** |
| 是否有第三方运行时依赖 | **没有**（无 SPM、CocoaPods、Carthage、无 vendored 源码） |
| 是否复制了他人源码 | **没有**（22 个 Swift 文件、着色器与图标脚本均为本次原创） |
| 是否内置第三方素材（图片/字体/音频） | **没有**（图标由仓库内脚本绘制，字体只用系统字体） |
| 名称是否与他人重名 | 在 App Store 与 GitHub 未发现同名软件；商标数据库未检索（见风险 4） |
| 代码许可 | MIT（见仓库根目录 `LICENSE`），版权人 zhangzhouqi |

一句话：这是一份干净的、零依赖的原生 macOS 工程；真正的合规风险不在版权，而在**私有 API** 与**歌词内容版权**两处，已在下文单列。

---

## 二、审查方法

```bash
# 1. 依赖：工程里有没有引用任何包
grep -n "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency\|packageReferences" \
  Lyrascope.xcodeproj/project.pbxproj
# → 只有一行空的 packageProductDependencies = ( ); 没有任何包引用

find . -name "Package.swift" -o -name "*.podspec" -o -name "Podfile" \
       -o -name "Cartfile" -o -name "*.xcframework" -o -name "*.a" | grep -v .build
# → 空

find . \( -name "*.c" -o -name "*.h" -o -name "*.m" -o -name "*.mm" \
       -o -name "*.cpp" -o -name "*.rs" \) | grep -v .build
# → 空，没有任何 C/C++/ObjC 第三方源码

# 2. 许可关键字：源码里有没有别人家的许可头或 SPDX 标记
grep -rilE "GNU (General|Affero|Lesser)|GPL-?v?[23]|AGPL|Mozilla Public|Apache License|BSD [23]-Clause|SPDX" \
  Sources scripts Docs README.md
# → 仅 README.md 命中（那是本报告的“没有 GPL”这句话本身），源码零命中

# 3. 引用到的系统框架
grep -rh "^import" Sources | sort | uniq -c | sort -rn
# → SwiftUI / AppKit / Foundation / os / QuartzCore / Combine / ServiceManagement /
#   ScreenCaptureKit / MetalKit / Metal / CoreAudio / Carbon.HIToolbox / Accelerate / AVFoundation
#   全部是 Apple SDK 自带框架

# 4. 资源
find Sources/Resources -type f
# → 只有 Assets.xcassets 里的 AppIcon 十张位图 + 两个 Contents.json
```

统计：22 个 Swift 文件、约 6 000 行；1 个内嵌 Metal 着色器字符串；1 个图标生成脚本；无二进制库、无网络 SDK、无统计 SDK。

---

## 三、Apple 框架使用情况

| 框架 | 用途 | 许可 |
| --- | --- | --- |
| CoreAudio | 进程 Tap、聚合设备、IOProc | 随 macOS SDK，系统框架（Apple 系统软件许可） |
| AVFoundation / Accelerate | 音频格式与 vDSP FFT | 同上 |
| ScreenCaptureKit | 备选采集路径 | 同上 |
| Metal / MetalKit | 可视化渲染 | 同上 |
| SwiftUI / AppKit | 界面 | 同上 |
| ServiceManagement | 登录时启动 | 同上 |
| Carbon.HIToolbox | 全局热键（`RegisterEventHotKey`） | 同上 |
| Translation（macOS 15+） | 歌词本地翻译 | 同上 |
| Foundation / Combine / QuartzCore / os | 基础能力 | 同上 |

这些是「随系统提供的框架」，不构成在仓库里分发第三方代码，也不需要附带任何第三方许可文本。

---

## 四、原创性说明（算法与公式）

- **K 加权响度**：滤波器系数（`f0 = 1681.97…`、`G = 3.9998…`、`Q = 0.7071…` 等）来自 ITU-R BS.1770 公开标准里的公式与常数。标准文本中的公式属于事实性技术信息，本项目按公式自行实现代码，未复制任何实现库的源码。
- **FFT / 窗函数 / 相位**：全部调用 Accelerate 的 `vDSP`，没有搬运第三方 FFT 实现。
- **频谱通量节拍检测、对数频段、峰值帽衰减**：常见 DSP 教科书方法，自行实现。
- **着色器**：值噪声（value noise）、fbm、极光帘幕、径向频谱、heatmap 都是图形学里的常规写法，逐行本项目自写；没有从 Shadertoy 或任何仓库拷贝片段。着色器以字符串内嵌，方便审查，也避免了 Xcode 26 的 Metal 工具链依赖。
- **工程模板**：`project.pbxproj` 的结构参考了同一作者自己的项目 `LidAwake`（自有代码），`Docs` 与 `scripts/build.sh` 的流程同样沿用作者既有习惯。这不涉及第三方。
- **图标**：`scripts/make_icon.swift` 用 AppKit 现画（圆角底板 + 72 根频谱柱），十张位图由脚本生成，不含任何外部素材。
- **字体**：只用系统字体（SF Pro / SF Mono），没有打包字体文件。

---

## 五、名称检索

检索时间 2026-11-15：

| 来源 | 查询 | 结果 |
| --- | --- | --- |
| iTunes Search API（`entity=macSoftware`） | `lyrascope` | 3 条模糊结果（ScopeWizard、Groovy Stars、Meridian），**没有同名 App** |
| iTunes Search API（`entity=software`） | `lyrascope` | 5 条模糊结果，无同名 |
| GitHub Search API（repositories） | `lyrascope` | `total_count = 0` |
| 本地工作区 | — | 无同名项目（用户已有 Lumen / LidAwake / FocusGuard 等，均不冲突） |

候选名淘汰记录：Auralis、vythm、LyricGlow、FlowX、LyricFever 均已被占用；Auraloom 与 GitHub 上的 `auraloom-spicetify` 及 App Store 近似项冲突；`Lumen` 已被用户自己的项目占用。最终选 `Lyrascope`，Bundle ID `com.zhangzhouqi.Lyrascope`，中文副标题「词镜」。

---

## 六、风险清单与建议

### 1. MediaRemote 私有 API（中风险，非版权）

`NowPlaying.swift` 通过 `dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote")` 读取正在播放信息。这是**私有框架**：

- 不影响本机运行，也不会因为「用了私有 API」而侵犯版权；
- 但 Apple 可能在系统更新中改签名或移除符号，届时读取会失效（代码已准备 AppleScript 后备路径）；
- 若计划上架 Mac App Store，审核可能对此提出问题，建议上架前改为只用 `Music.app` 的 AppleScript / `MPNowPlayingInfoCenter` 公开能力，或接受被拒风险。

### 2. 歌词内容版权（中风险，取决于分发方式）

- App **不内置**任何歌词，也不抓取 Apple Music 的在线歌词；只读取用户本机文件、Apple Music 本地曲目自带歌词、以及 LRCLIB 的社区歌词。
- 桌面歌词属于「本机展示」，不涉及再分发；但如果将来做「导出歌词」「分享歌词卡片」功能，就会触碰复制权与信息网络传播权，需要单独的授权评估。
- 建议：在设置「关于」页保留歌词来源说明（已实现），并避免任何形式的歌词导出。

### 3. App Sandbox 与分发（合规风险，非版权）

- 工程里 `ENABLE_APP_SANDBOX = NO`、`ENABLE_HARDENED_RUNTIME = NO`、ad-hoc 签名，因为进程 Tap + AppleScript 在沙箱里受限。
- 这意味着**不能直接上架 Mac App Store**；对外分发需要自己的 Developer ID 证书并公证（notarization），或者只自用。
- 若要上架，需要改成 ScreenCaptureKit 音频采集 + 沙箱 + 用户主动授权，工程量不小。

### 4. 商标（低风险，需正式检索）

- 目前只检索了 App Store 与 GitHub，**没有**检索 USPTO / EUIPO / CNIPA 商标库。
- 「Lyrascope」是自造词，重名概率低；若打算商业化，建议在目标市场做一次正式商标检索与注册。

### 5. 设计参考（无风险）

- 视觉方向参考了 Apple Music 的「歌词 + 封面」气质与常见的音频可视化范式，但没有复制任何界面素材、图标或布局文件；所有控件由 SwiftUI 从零绘制。

---

## 七、如果要再保守一点

1. 把 MediaRemote 换成公开 API（`ScriptingBridge` / AppleScript），彻底移除私有框架依赖。
2. 关闭 LRCLIB（设置里已有开关），只保留本地 `.lrc` 与 Apple Music 本地歌词。
3. 若要发布，补一份 `THIRD-PARTY-NOTICES.md`（当前为空，因为确实没有第三方代码）。
4. 在仓库加 CI，用 `grep` 守住「不新增第三方依赖」这条线。
