//
//  OnboardingView.swift
//  Lyrascope
//

import SwiftUI

struct OnboardingView: View {

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var accent: Theme.Accent { Theme.accent(settings.lyricsAccent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Lyrascope")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("词镜 · 让 Apple Music 有画面，也有歌词")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.gradient(settings.lyricsAccent))
                    .frame(width: 74, height: 74)
                    .overlay {
                        Image(systemName: "waveform.path")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.black.opacity(0.72))
                    }
            }

            VStack(spacing: 2) {
                feature(
                    symbol: "sparkles",
                    title: "两种可视化",
                    detail: "流光视图给听众，制作人视图给混音——频谱瀑布、示波器、声像仪与 LUFS 表都在。"
                )
                feature(
                    symbol: "text.quote",
                    title: "桌面与菜单栏歌词",
                    detail: "自动寻找 LRC 时间轴，逐字高亮，可以拖到屏幕任何角落，也可以只留在菜单栏。"
                )
                feature(
                    symbol: "waveform",
                    title: "只读系统声音",
                    detail: "通过 Core Audio 的进程音频 Tap 读取播放中的音乐，不打开麦克风，不上传任何数据。"
                )
            }

            Spacer(minLength: 4)

            HStack(spacing: 10) {
                Text("首次播放时，macOS 可能要求你允许 Lyrascope 录制系统音频。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                PillButton(title: "开始使用", systemName: "arrow.right", prominent: true, accent: accent.primary) {
                    settings.hasCompletedOnboarding = true
                    dismiss()
                }
            }
        }
        .padding(32)
        .frame(width: 640, height: 470)
        .background(Theme.canvas)
    }

    private func feature(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent.primary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(accent.primary.opacity(0.10))
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}
