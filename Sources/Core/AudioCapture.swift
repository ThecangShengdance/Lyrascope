//
//  AudioCapture.swift
//  Lyrascope
//
//  系统音频采集：优先使用 Core Audio 进程 Tap（macOS 14.2+），
//  备选 ScreenCaptureKit 音频流。两条路径最终都回调同一份左右声道 PCM。
//

import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit
import os

// MARK: - 错误

enum AudioCaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case streamConfigurationFailed(String)
    case noDisplay
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "创建系统音频 Tap 失败（\(status)）。请在「系统设置 › 隐私与安全性 › 音频录制」中允许 Lyrascope。"
        case .aggregateCreationFailed(let status):
            return "创建聚合音频设备失败（\(status)）。"
        case .ioProcFailed(let status):
            return "注册音频回调失败（\(status)）。"
        case .deviceStartFailed(let status):
            return "启动音频设备失败（\(status)）。"
        case .streamConfigurationFailed(let message):
            return "屏幕音频采集失败：\(message)"
        case .noDisplay:
            return "没有找到可用的显示器。"
        case .screenRecordingDenied:
            return "需要在「系统设置 › 隐私与安全性 › 屏幕录制」中允许 Lyrascope。"
        }
    }
}

// MARK: - 采集状态

enum AudioCaptureState: Equatable {
    case idle
    case starting
    case running(description: String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "未开始"
        case .starting: return "正在启动…"
        case .running(let description): return description
        case .failed(let message): return message
        }
    }
}

// MARK: - 系统音频采集

/// 把系统正在播放的声音变成 Float32 PCM。不会录入麦克风。
final class SystemAudioCapture: NSObject {

    typealias Sink = (_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frameCount: Int, _ sampleRate: Double) -> Void

    /// 音频回调（在 Core Audio 的 IO 线程或 SCK 队列上调用）。
    var sink: Sink?

    private(set) var isRunning = false
    /// 最后一次收到音频数据的时刻（CFAbsoluteTime），用来判断回调是否已经停了。
    private(set) var lastCallbackTime: CFAbsoluteTime = 0
    /// 调试用：IOProc 被调用的次数与最后看到的格式。
    private(set) var ioCallCount = 0
    private(set) var lastFormatNote = "-"
    private(set) var sampleRate: Double = 48_000
    private(set) var state: AudioCaptureState = .idle

    // Core Audio Tap
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var streamFormat = AudioStreamBasicDescription()
    private var scratchLeft = [Float](repeating: 0, count: 16_384)
    private var scratchRight = [Float](repeating: 0, count: 16_384)

    // ScreenCaptureKit
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.zhangzhouqi.Lyrascope.sck.audio", qos: .userInteractive)
    private var sckFormat = AudioStreamBasicDescription()
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    /// 系统默认输出设备变化（插耳机、切 AirPods、切显示器音箱）时回调。
    var onOutputDeviceChange: (() -> Void)?

    func secondsSinceLastCallback() -> Double {
        guard lastCallbackTime > 0 else { return .greatestFiniteMagnitude }
        return CFAbsoluteTimeGetCurrent() - lastCallbackTime
    }

    private func deliver(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        lastCallbackTime = CFAbsoluteTimeGetCurrent()
        sink?(left, right, frames, sampleRate)
    }

    /// 监听默认输出设备变化：聚合设备里的子设备一旦被换掉，IOProc 会静默停掉。
    func installOutputDeviceListener() {
        guard outputDeviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.onOutputDeviceChange?() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        if status == noErr {
            outputDeviceListener = block
        }
    }

    func removeOutputDeviceListener() {
        guard let block = outputDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        outputDeviceListener = nil
    }

    // MARK: 启动

    func start(mode: CaptureMode) async throws {
        stop()
        installOutputDeviceListener()
        state = .starting
        switch mode {
        case .systemTap:
            try startProcessTap()
        case .screenCapture:
            try await startScreenCapture()
        }
        isRunning = true
        state = .running(description: mode == .systemTap ? "Core Audio Tap" : "屏幕录制音频")
    }

    func stop() {
        stopProcessTap()
        stopScreenCapture()
        isRunning = false
        if state.isRunning || state == .starting { state = .idle }
    }

    // MARK: - 方案 A：Core Audio 进程 Tap

    private func startProcessTap() throws {
        guard #available(macOS 14.2, *) else {
            throw AudioCaptureError.tapCreationFailed(-1)
        }

        let ownProcess = Self.audioProcessObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [AudioObjectID($0)] } ?? [])
        description.name = "Lyrascope System Audio"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted // 用户仍然能听见声音

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else { throw AudioCaptureError.tapCreationFailed(tapStatus) }
        tapID = tap

        let aggregateUID = "Lyrascope-\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lyrascope Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioCaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = aggregate

        streamFormat = Self.inputFormat(of: aggregate)
        if streamFormat.mSampleRate > 0 {
            sampleRate = streamFormat.mSampleRate
        }

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.ioCallCount += 1
            self.consume(ioData: UnsafeMutablePointer(mutating: inputData), format: self.streamFormat)
        }
        guard procStatus == noErr, let procID else {
            cleanupTapObjects()
            throw AudioCaptureError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            cleanupTapObjects()
            throw AudioCaptureError.deviceStartFailed(startStatus)
        }
        if ProcessInfo.processInfo.environment["LYRA_DEBUG"] != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                var running: UInt32 = 0
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunning,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<UInt32>.size)
                let status = AudioObjectGetPropertyData(self.aggregateID, &address, 0, nil, &size, &running)
                FileHandle.standardError.write(Data("LYRA tap tapID=\(self.tapID) agg=\(self.aggregateID) startStatus=\(startStatus) running=\(running) status=\(status) io=\(self.ioCallCount) fmtRate=\(self.streamFormat.mSampleRate) ch=\(self.streamFormat.mChannelsPerFrame)\n".utf8))
            }
        }
    }

    private func stopProcessTap() {
        if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanupTapObjects()
    }

    private func cleanupTapObjects() {
        if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// 处理 Core Audio 的 AudioBufferList（兼容交错 / 非交错）。
    private func consume(ioData: UnsafeMutablePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        lastFormatNote = "bufs=\(buffers.count) flags=\(format.mFormatFlags) ch=\(format.mChannelsPerFrame) bpf=\(format.mBytesPerFrame) first=\(buffers.first?.mDataByteSize ?? 0)"
        guard !buffers.isEmpty else { return }

        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = max(1, Int(format.mChannelsPerFrame))
        let bytesPerFrame = max(1, Int(format.mBytesPerFrame))
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if !isFloat {
            // Tap 一律是 Float32；万一不是就跳过，避免噪声。
            return
        }

        if isNonInterleaved || buffers.count >= 2 {
            guard let leftData = buffers[0].mData, let rightData = buffers.count > 1 ? buffers[1].mData : buffers[0].mData else { return }
            let frames = min(
                Int(buffers[0].mDataByteSize) / max(4, bytesPerFrame),
                Int(buffers.count > 1 ? buffers[1].mDataByteSize : buffers[0].mDataByteSize) / max(4, bytesPerFrame),
                scratchLeft.count
            )
            guard frames > 0 else { return }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            if channels > 1 && !isNonInterleaved && buffers.count == 1 {
                // 交错立体声：拆分
                for index in 0..<frames {
                    scratchLeft[index] = left[index * channels]
                    scratchRight[index] = left[index * channels + 1]
                }
                scratchLeft.withUnsafeBufferPointer { l in
                    scratchRight.withUnsafeBufferPointer { r in
                        deliver(left: l.baseAddress!, right: r.baseAddress!, frames: frames, sampleRate: sampleRate)
                    }
                }
            } else {
                deliver(left: left, right: right, frames: frames, sampleRate: sampleRate)
            }
        } else {
            // 单缓冲区交错
            guard let data = buffers[0].mData else { return }
            let pointer = data.assumingMemoryBound(to: Float.self)
            let frames = min(Int(buffers[0].mDataByteSize) / max(4, bytesPerFrame), scratchLeft.count)
            guard frames > 0 else { return }
            if channels >= 2 {
                for index in 0..<frames {
                    scratchLeft[index] = pointer[index * channels]
                    scratchRight[index] = pointer[index * channels + 1]
                }
                scratchLeft.withUnsafeBufferPointer { l in
                    scratchRight.withUnsafeBufferPointer { r in
                        deliver(left: l.baseAddress!, right: r.baseAddress!, frames: frames, sampleRate: sampleRate)
                    }
                }
            } else {
                deliver(left: pointer, right: pointer, frames: frames, sampleRate: sampleRate)
            }
        }
    }

    // MARK: - 方案 B：ScreenCaptureKit

    private func startScreenCapture() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw AudioCaptureError.screenRecordingDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw AudioCaptureError.streamConfigurationFailed(error.localizedDescription)
        }

        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // 视频流尽量小，我们只要音频。
        configuration.width = 32
        configuration.height = 32
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        do {
            try await stream.startCapture()
        } catch {
            throw AudioCaptureError.streamConfigurationFailed(error.localizedDescription)
        }
        self.stream = stream
        sampleRate = Double(configuration.sampleRate)
    }

    private func stopScreenCapture() {
        guard let stream else { return }
        stream.stopCapture { _ in }
        self.stream = nil
    }

    // MARK: - 工具

    private static func audioProcessObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pointer,
                &size,
                &processObject
            )
        }
        guard status == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return processObject
    }

    private static func inputFormat(of device: AudioObjectID) -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format)
        if status != noErr || format.mSampleRate == 0 {
            format.mSampleRate = 48_000
            format.mChannelsPerFrame = 2
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            format.mBytesPerFrame = 8
            format.mFramesPerPacket = 1
            format.mBitsPerChannel = 32
        }
        return format
    }
}

// MARK: - ScreenCaptureKit 音频代理

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let format = asbdPointer.pointee
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 8
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let data = first.mData else { return }

        let channels = max(1, Int(format.mChannelsPerFrame))
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat else { return }

        if isNonInterleaved && buffers.count >= 2, let rightData = buffers[1].mData {
            let frames = min(Int(first.mDataByteSize) / 4, Int(buffers[1].mDataByteSize) / 4)
            guard frames > 0 else { return }
            deliver(
                left: data.assumingMemoryBound(to: Float.self),
                right: rightData.assumingMemoryBound(to: Float.self),
                frames: frames,
                sampleRate: sampleRate
            )
        } else {
            let frames = min(Int(first.mDataByteSize) / (4 * channels), scratchLeft.count)
            guard frames > 0 else { return }
            let interleaved = data.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                scratchLeft[index] = channels >= 2 ? interleaved[index * channels] : interleaved[index]
                scratchRight[index] = channels >= 2 ? interleaved[index * channels + 1] : interleaved[index]
            }
            scratchLeft.withUnsafeBufferPointer { left in
                scratchRight.withUnsafeBufferPointer { right in
                    deliver(left: left.baseAddress!, right: right.baseAddress!, frames: frames, sampleRate: sampleRate)
                }
            }
        }
    }
}
