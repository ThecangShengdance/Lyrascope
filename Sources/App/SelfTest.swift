//
//  SelfTest.swift
//  Lyrascope
//
//  一个不依赖界面、不上屏的自检：LRC 解析、频谱与响度、着色器编译。
//  用法：Lyrascope --selftest
//

import Foundation

enum SelfTest {

    static func run() -> Never {
        var failures: [String] = []
        var passes = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                passes += 1
                print("  ✓ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                failures.append(name + (detail.isEmpty ? "" : " — \(detail)"))
                print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        print("Lyrascope 自检")
        print("")

        // MARK: LRC 解析

        print("[1/3] LRC 解析")
        let lrc = """
        [ti:Mirror Test]
        [ar:zhangzhouqi]
        [al:Self Test]
        [offset:0]
        [00:00.00]First line
        [00:03.20]Second line
        [00:06.50]Third <00:06.50>line
        [00:09.00]Fourth line
        [00:12.00]Fifth line
        """
        let document = LRCParser.parse(lrc, source: .plainText)
        check("解析出 5 行", document.lines.count == 5, "实际 \(document.lines.count) 行")
        check("时间轴正确", document.lines.count > 1 && abs(document.lines[1].time - 3.2) < 0.001)
        check("元数据读取", document.title == "Mirror Test", "title=\(document.title ?? "nil")")
        check("按位置取行", document.index(at: 4.0) == 1, "index=\(document.index(at: 4.0))")
        check("末行结束时间", document.endTime(of: 4) > 12.0)
        check("歌词行时间递增", zip(document.lines, document.lines.dropFirst()).allSatisfy { $0.time <= $1.time })

        // 纯文本歌词：按曲长估时间轴，至少能跟着音乐往下走
        var plain = LRCParser.parse("第一句\n第二句\n第三句\n第四句\n第五句", source: .appleMusic)
        check("纯文本判定为无时间轴", plain.isSynced == false)
        plain.applyEstimatedTiming(duration: 200)
        check("估算后变成有时间轴", plain.isSynced && plain.isEstimated)
        check("估算时间轴单调递增",
              plain.lines.count == 5 && zip(plain.lines, plain.lines.dropFirst()).allSatisfy { $0.time < $1.time })

        // 翻译合并
        var translated = document
        translated.mergeTranslations([0: "第一行译文", 2: "第三行译文"])
        check("合并翻译", translated.lines[0].translation == "第一行译文" && translated.lines[2].translation == "第三行译文")
        check("已有翻译不被覆盖", {
            var copy = translated
            copy.mergeTranslations([0: "新译文"])
            return copy.lines[0].translation == "第一行译文"
        }())

        // MARK: 分析器

        print("")
        print("[2/3] 频谱与响度")

        let analyzer = SpectrumAnalyzer()
        let sampleRate = 48_000.0
        let frameSize = 4096
        var left = [Float](repeating: 0, count: frameSize)
        var right = [Float](repeating: 0, count: frameSize)
        for index in 0..<frameSize {
            let value = Float(sin(2.0 * Double.pi * 1000.0 * Double(index) / sampleRate) * 0.5)
            left[index] = value
            right[index] = value
        }

        for _ in 0..<90 {
            left.withUnsafeBufferPointer { leftPointer in
                right.withUnsafeBufferPointer { rightPointer in
                    analyzer.ingest(
                        left: leftPointer.baseAddress!,
                        right: rightPointer.baseAddress!,
                        frames: frameSize,
                        sampleRate: sampleRate
                    )
                }
            }
            analyzer.tick(deltaTime: 1.0 / 60.0)
        }

        let frame = analyzer.snapshot()
        let loudestBand = frame.bands.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
        check("1 kHz 正弦的能量集中在中频段", (45...62).contains(loudestBand), "峰值频段 #\(loudestBand)")
        check("响度已计算", frame.loudness > -20 && frame.loudness < 0, String(format: "%.1f LUFS", frame.loudness))
        check("不是静音", !frame.isSilent)
        check("立体声相关度为 +1", abs(frame.correlation - 1.0) < 0.05, String(format: "%.3f", frame.correlation))
        check("波形有数据", frame.waveform.contains(where: { abs($0) > 0.01 }))
        check("声像点有数据", frame.scope.contains(where: { abs($0.x) > 0.01 || abs($0.y) > 0.01 }))

        // MARK: 着色器

        print("")
        print("[3/3] Metal 着色器")
        let (shaderOK, shaderDetail) = MetalSupport.validateShaderCompilation()
        check("运行时编译着色器", shaderOK, shaderDetail)

        print("")
        if failures.isEmpty {
            print("全部通过：\(passes) 项。")
            exit(0)
        } else {
            print("失败 \(failures.count) 项：")
            for failure in failures { print("  · \(failure)") }
            exit(1)
        }
    }
}
