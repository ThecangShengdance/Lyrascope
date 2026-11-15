//
//  LyricsTranslation.swift
//  Lyrascope
//
//  用系统「翻译」框架在本地补一份歌词翻译。
//  只对同步歌词、且原歌词没有自带翻译时生效；失败就静默跳过，不影响其它功能。
//

import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 一次翻译任务。视图层拿到它以后，用 `.translationTask` 起一个系统会话。
struct TranslationJob: Equatable {
    let id: Int
    let texts: [String]
    let target: String
}

@MainActor
final class LyricsTranslator: ObservableObject {

    /// 视图层监听这个值来触发系统翻译会话。
    @Published private(set) var job: TranslationJob?

    private var completion: (([String]) -> Void)?
    private var nextID = 1

    /// 系统语言决定翻译成什么。中文环境译成简体中文，其它环境译成英语。
    static var targetLanguageIdentifier: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        switch code {
        case "zh": return "zh-Hans"
        case "en": return "en"
        default: return code
        }
    }

    /// 粗略判断文本是不是已经是目标语言，避免把中文歌词再翻一遍。
    static func isAlreadyTargetLanguage(_ text: String, target: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return false }
        let dominantCode = dominant.rawValue.lowercased()
        let targetCode = target.lowercased()
        if targetCode.hasPrefix("zh") { return dominantCode.hasPrefix("zh") }
        return dominantCode == targetCode
    }

    func submit(texts: [String], completion: @escaping ([String]) -> Void) {
        guard !texts.isEmpty else { return }
        nextID += 1
        self.completion = completion
        job = TranslationJob(id: nextID, texts: texts, target: Self.targetLanguageIdentifier)
    }

    func finish(_ translations: [String]) {
        let handler = completion
        completion = nil
        job = nil
        handler?(translations)
    }

    func cancel() {
        completion = nil
        job = nil
    }
}

// MARK: - 视图宿主

/// 挂在主界面上的隐藏宿主：有任务时创建一次 `TranslationSession`，译完就清空。
struct TranslationHostModifier: ViewModifier {

    @EnvironmentObject private var translator: LyricsTranslator

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.background(TranslationRunner(translator: translator).frame(width: 0, height: 0))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationRunner: View {

    @ObservedObject var translator: LyricsTranslator
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onChange(of: translator.job) { _, job in
                guard let job else {
                    configuration = nil
                    return
                }
                configuration = TranslationSession.Configuration(
                    source: nil,
                    target: Locale.Language(identifier: job.target)
                )
            }
            .translationTask(configuration) { session in
                guard let job = translator.job else { return }
                var results: [String] = []
                do {
                    // 语言包没装时会抛错，这里静默放弃，用户不会看到报错弹窗。
                    try await session.prepareTranslation()
                    let batchSize = 40
                    var index = 0
                    while index < job.texts.count {
                        let end = min(index + batchSize, job.texts.count)
                        let chunk = Array(job.texts[index..<end])
                        let responses = try await session.translations(
                            from: chunk.map { TranslationSession.Request(sourceText: $0) }
                        )
                        results.append(contentsOf: responses.map(\.targetText))
                        index = end
                    }
                } catch {
                    results = []
                }
                await MainActor.run {
                    translator.finish(results)
                }
            }
    }
}

extension View {
    func translationHost() -> some View { modifier(TranslationHostModifier()) }
}
