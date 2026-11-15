//
//  AudioAnalyzer.swift
//  Lyrascope
//
//  FFT、频段、响度、声像、节拍。全部在本地完成，不上传任何音频。
//

import Accelerate
import Foundation
import QuartzCore
import os

// MARK: - 一帧分析结果

struct AudioFrame {
    static let bandCount = 96
    static let scopeCount = 192
    static let waveformCount = 256

    var bands: [Float] = Array(repeating: 0, count: AudioFrame.bandCount)
    var peaks: [Float] = Array(repeating: 0, count: AudioFrame.bandCount)
    var waveform: [Float] = Array(repeating: 0, count: AudioFrame.waveformCount)
    var scope: [SIMD2<Float>] = Array(repeating: .zero, count: AudioFrame.scopeCount)

    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var level: Float = 0
    var peak: Float = 0
    /// ITU-R BS.1770 K 加权近似响度（LUFS）。静音时是 -70。
    var loudness: Float = -70
    /// 立体声相关度：-1 反相，0 无关，+1 单声道。
    var correlation: Float = 0
    /// 节拍冲量，0…1，随时间衰减。
    var beat: Float = 0
    var centroid: Float = 0.5
    var isSilent: Bool = true
    var sampleRate: Double = 48_000

    static let empty = AudioFrame()
}

// MARK: - 环形缓冲

/// 音频线程写、主线程读的立体声环形缓冲。
final class StereoRingBuffer {
    private let capacity: Int
    private var left: [Float]
    private var right: [Float]
    private var writeIndex = 0
    private var stored = 0
    private var lock = os_unfair_lock_s()

    init(capacity: Int = 1 << 16) {
        self.capacity = capacity
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
    }

    func write(left sourceLeft: UnsafePointer<Float>, right sourceRight: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let frames = min(frames, capacity)
        let firstChunk = min(frames, capacity - writeIndex)
        left.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.advanced(by: writeIndex).update(from: sourceLeft, count: firstChunk)
            right.withUnsafeMutableBufferPointer { destinationRight in
                destinationRight.baseAddress!.advanced(by: writeIndex).update(from: sourceRight, count: firstChunk)
            }
        }
        if frames > firstChunk {
            let remaining = frames - firstChunk
            left.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: sourceLeft.advanced(by: firstChunk), count: remaining)
            }
            right.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.update(from: sourceRight.advanced(by: firstChunk), count: remaining)
            }
        }
        writeIndex = (writeIndex + frames) % capacity
        stored = min(capacity, stored + frames)
    }

    /// 读取最多 `maxFrames` 帧（从最旧的数据开始）。
    func read(into leftOut: inout [Float], rightOut: inout [Float], maxFrames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let count = min(maxFrames, stored)
        guard count > 0 else { return 0 }
        let start = (writeIndex - stored + capacity) % capacity
        let firstChunk = min(count, capacity - start)
        leftOut.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: left, count: firstChunk)
            rightOut.withUnsafeMutableBufferPointer { destinationRight in
                destinationRight.baseAddress!.update(from: right, count: firstChunk)
            }
        }
        if count > firstChunk {
            let remaining = count - firstChunk
            leftOut.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + firstChunk).update(from: left, count: remaining)
            }
            rightOut.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + firstChunk).update(from: right, count: remaining)
            }
        }
        stored -= count
        return count
    }
}

// MARK: - 分析器

final class SpectrumAnalyzer {

    static let fftSize = 4096

    private let ring = StereoRingBuffer()
    private let fftSize = SpectrumAnalyzer.fftSize
    private let bandCount = AudioFrame.bandCount

    private var fftSetup: FFTSetup?
    private var hannWindow = [Float]()
    private var windowed = [Float]()
    private var magnitudes = [Float]()
    private var splitReal = [Float]()
    private var splitImag = [Float]()

    private var historyLeft: [Float]
    private var historyRight: [Float]
    private var mixBuffer = [Float]()
    private var filterBuffer = [Float]()

    private var drainLeft = [Float]()
    private var drainRight = [Float]()

    private var bandEdges: [(low: Int, high: Int)] = []
    private var bandCentreHz: [Float] = []
    private var smoothedBands = [Float]()
    private var peakBands = [Float]()
    private var previousBands = [Float]()

    /// 输入增益（0…2）。安静的音乐也能撑起画面。
    var gain: Float = 1

    private var beatFluxHistory = [Float]()
    private var beatPulse: Float = 0
    private var lastBeatTime: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var hasSetup = false

    private var frameLock = os_unfair_lock_s()
    private var currentFrame = AudioFrame()

    // K 加权系数（ITU-R BS.1770）
    private var shelfCoefficients: [Double] = [0, 0, 0, 0, 0]
    private var highPassCoefficients: [Double] = [0, 0, 0, 0, 0]
    private var filterSampleRate: Double = 0

    init() {
        historyLeft = [Float](repeating: 0, count: fftSize)
        historyRight = [Float](repeating: 0, count: fftSize)
        smoothedBands = [Float](repeating: 0, count: bandCount)
        peakBands = [Float](repeating: 0, count: bandCount)
        previousBands = [Float](repeating: 0, count: bandCount)
        drainLeft = [Float](repeating: 0, count: fftSize * 4)
        drainRight = [Float](repeating: 0, count: fftSize * 4)
        setUpIfNeeded()
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    // MARK: 写入音频

    func ingest(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        ring.write(left: left, right: right, frames: frames)
        if abs(sampleRate - filterSampleRate) > 1 {
            updateFilterCoefficients(sampleRate: sampleRate)
        }
    }

    // MARK: 分析

    /// 由主线程以约 60 Hz 调用。
    func tick(deltaTime: TimeInterval) {
        let dt = Float(max(0.001, min(0.1, deltaTime)))
        let available = ring.read(into: &drainLeft, rightOut: &drainRight, maxFrames: fftSize)
        if available > 0 {
            pushHistory(left: drainLeft, right: drainRight, count: available)
        }
        guard hasSetup else { return }

        computeSpectrum()
        computeStereoAndWaveform()
        computeLoudness()
        updateBands(deltaTime: dt)
        updateBeat(deltaTime: dt)

        var frame = AudioFrame()
        frame.bands = smoothedBands
        frame.peaks = peakBands
        frame.waveform = makeWaveform()
        frame.scope = makeScope()
        frame.bass = meanBand(0..<10)
        frame.mid = meanBand(18..<52)
        frame.treble = meanBand(60..<bandCount)
        frame.level = levelFromRMS()
        frame.peak = peakLevel
        frame.loudness = loudnessValue
        frame.correlation = stereoCorrelation
        frame.beat = beatPulse
        frame.centroid = spectralCentroid()
        frame.isSilent = silenceDuration > 0.8
        frame.sampleRate = filterSampleRate > 0 ? filterSampleRate : 48_000

        let appliedGain = max(0, min(2, gain))
        if abs(appliedGain - 1) > 0.001 {
            for index in frame.bands.indices {
                frame.bands[index] = min(1, frame.bands[index] * appliedGain)
            }
            for index in frame.peaks.indices {
                frame.peaks[index] = min(1, frame.peaks[index] * appliedGain)
            }
            for index in frame.waveform.indices {
                frame.waveform[index] = max(-1, min(1, frame.waveform[index] * appliedGain))
            }
            frame.bass = min(1, frame.bass * appliedGain)
            frame.mid = min(1, frame.mid * appliedGain)
            frame.treble = min(1, frame.treble * appliedGain)
            frame.level = min(1, frame.level * appliedGain)
        }

        os_unfair_lock_lock(&frameLock)
        currentFrame = frame
        os_unfair_lock_unlock(&frameLock)
    }

    func snapshot() -> AudioFrame {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return currentFrame
    }

    // MARK: - 初始化

    private func setUpIfNeeded() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        fftSetup = setup
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        splitReal = [Float](repeating: 0, count: fftSize / 2)
        splitImag = [Float](repeating: 0, count: fftSize / 2)
        mixBuffer = [Float](repeating: 0, count: fftSize)
        filterBuffer = [Float](repeating: 0, count: fftSize)
        buildBandEdges()
        updateFilterCoefficients(sampleRate: 48_000)
        hasSetup = true
    }

    private func buildBandEdges() {
        let sampleRate = 48_000.0
        let lowest = 25.0
        let highest = min(19_000.0, sampleRate / 2 - 100)
        let ratio = pow(highest / lowest, 1.0 / Double(bandCount - 1))
        bandEdges = (0..<bandCount).map { index in
            let center = lowest * pow(ratio, Double(index))
            let low = center / pow(ratio, 0.5)
            let high = center * pow(ratio, 0.5)
            let binWidth = sampleRate / Double(fftSize)
            let lowBin = max(1, Int(low / binWidth))
            let highBin = max(lowBin + 1, min(fftSize / 2 - 1, Int(high / binWidth) + 1))
            return (lowBin, highBin)
        }
        bandCentreHz = (0..<bandCount).map { index in
            Float(lowest * pow(ratio, Double(index)))
        }
    }

    private func pushHistory(left: [Float], right: [Float], count: Int) {
        let amount = min(count, fftSize)
        guard amount > 0 else { return }
        if amount < fftSize {
            _ = historyLeft.withUnsafeMutableBufferPointer { buffer in
                memmove(buffer.baseAddress!, buffer.baseAddress! + amount, (fftSize - amount) * MemoryLayout<Float>.size)
            }
            _ = historyRight.withUnsafeMutableBufferPointer { buffer in
                memmove(buffer.baseAddress!, buffer.baseAddress! + amount, (fftSize - amount) * MemoryLayout<Float>.size)
            }
        }
        left.withUnsafeBufferPointer { source in
            historyLeft.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + (fftSize - amount)).update(from: source.baseAddress! + (count - amount), count: amount)
            }
        }
        right.withUnsafeBufferPointer { source in
            historyRight.withUnsafeMutableBufferPointer { destination in
                (destination.baseAddress! + (fftSize - amount)).update(from: source.baseAddress! + (count - amount), count: amount)
            }
        }
    }

    // MARK: - 频谱

    private func computeSpectrum() {
        // 单声道混合，避免两声道相位抵消带来的视觉抖动。
        vDSP_vadd(historyLeft, 1, historyRight, 1, &mixBuffer, 1, vDSP_Length(fftSize))
        var half: Float = 0.5
        vDSP_vsmul(mixBuffer, 1, &half, &mixBuffer, 1, vDSP_Length(fftSize))
        vDSP_vmul(mixBuffer, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        splitReal.withUnsafeMutableBufferPointer { realPointer in
            splitImag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup!, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // zrip 结果需要乘以 2；Hann 窗相干增益 0.5，再补 2。
        var scale = 4.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(fftSize / 2))
        for index in 0..<magnitudes.count {
            magnitudes[index] = 20 * log10(max(magnitudes[index], 1e-7))
        }
    }

    // MARK: - 波形 / 声像

    private var waveBuffer = [Float](repeating: 0, count: AudioFrame.waveformCount)
    private var scopeBuffer = [SIMD2<Float>](repeating: .zero, count: AudioFrame.scopeCount)
    private var peakLevel: Float = 0
    private var stereoCorrelation: Float = 0

    private func computeStereoAndWaveform() {
        let stride = fftSize / AudioFrame.waveformCount
        var peak: Float = 0
        for index in 0..<AudioFrame.waveformCount {
            let sourceIndex = index * stride
            let value = (historyLeft[sourceIndex] + historyRight[sourceIndex]) * 0.5
            waveBuffer[index] = max(-1, min(1, value * 3))
            peak = max(peak, abs(value))
        }
        peakLevel = max(peakLevel * 0.92, min(1, peak))

        var sumLR: Float = 0
        var sumLL: Float = 0
        var sumRR: Float = 0
        let scopeStride = fftSize / AudioFrame.scopeCount
        for index in 0..<AudioFrame.scopeCount {
            let sourceIndex = index * scopeStride
            let l = historyLeft[sourceIndex]
            let r = historyRight[sourceIndex]
            scopeBuffer[index] = SIMD2<Float>(max(-1, min(1, l)), max(-1, min(1, r)))
            sumLR += l * r
            sumLL += l * l
            sumRR += r * r
        }
        let denominator = sqrt(max(sumLL * sumRR, 1e-12))
        stereoCorrelation = max(-1, min(1, sumLR / denominator))
    }

    private func makeWaveform() -> [Float] { waveBuffer }
    private func makeScope() -> [SIMD2<Float>] { scopeBuffer }

    // MARK: - 响度

    private var loudnessValue: Float = -70

    private func updateFilterCoefficients(sampleRate: Double) {
        guard sampleRate > 8_000 else { return }
        filterSampleRate = sampleRate

        // Stage 1: 高频搁架
        let f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(.pi * f0 / sampleRate)
        let vh = pow(10.0, gainDB / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        shelfCoefficients = [
            (vh + vb * k / q + k * k) / a0,
            2 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
            2 * (k * k - 1) / a0,
            (1 - k / q + k * k) / a0
        ]

        // Stage 2: 高通
        let hpF0 = 38.13547087602444
        let hpQ = 0.5003270373238773
        let hpK = tan(.pi * hpF0 / sampleRate)
        let hpA0 = 1 + hpK / hpQ + hpK * hpK
        highPassCoefficients = [
            1,
            -2,
            1,
            2 * (hpK * hpK - 1) / hpA0,
            (1 - hpK / hpQ + hpK * hpK) / hpA0
        ]
    }

    private func computeLoudness() {
        let count = fftSize
        guard filterSampleRate > 0 else { return }
        for index in 0..<count {
            filterBuffer[index] = (historyLeft[index] + historyRight[index]) * 0.5
        }
        applyBiquad(&filterBuffer, count: count, coefficients: shelfCoefficients)
        applyBiquad(&filterBuffer, count: count, coefficients: highPassCoefficients)

        var sum: Float = 0
        let skip = 128
        for index in skip..<count {
            sum += filterBuffer[index] * filterBuffer[index]
        }
        let meanSquare = max(sum / Float(count - skip), 1e-12)
        let lufs = -0.691 + 10 * log10(meanSquare)
        loudnessValue = max(-70, min(0, lufs))
    }

    private func applyBiquad(_ buffer: inout [Float], count: Int, coefficients: [Double]) {
        let b0 = Float(coefficients[0]), b1 = Float(coefficients[1]), b2 = Float(coefficients[2])
        let a1 = Float(coefficients[3]), a2 = Float(coefficients[4])
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for index in 0..<count {
            let x0 = buffer[index]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            buffer[index] = y0
        }
    }

    private func levelFromRMS() -> Float {
        var sum: Float = 0
        for index in 0..<fftSize {
            let value = (historyLeft[index] + historyRight[index]) * 0.5
            sum += value * value
        }
        let rms = sqrt(sum / Float(fftSize))
        guard rms > 1e-6 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 60))
    }

    // MARK: - 频段平滑

    private func updateBands(deltaTime: Float) {
        // 高频在音乐里天生比低频低十几 dB，补一条温和的高频倾斜，
        // 否则频谱会从 500 Hz 开始一路往下掉，柱子长短看起来才自然。
        for band in 0..<bandCount {
            let range = bandEdges[band]
            var peakDb: Float = -120
            for bin in range.low..<range.high where bin < magnitudes.count {
                peakDb = max(peakDb, magnitudes[bin])
            }
            let centerHz = max(40, bandCentreHz.indices.contains(band) ? bandCentreHz[band] : 1000)
            let tilt = min(10.5, max(-3, 7.5 * log2(centerHz / 900)))
            // 60 dB 窗口 + 幂次：比 80 dB 的映射更能拉开强弱，柱子才有起伏。
            let linear = max(0, min(1, (peakDb + tilt + 58) / 58))
            let target = pow(linear, 1.35)
            let current = smoothedBands[band]
            let tau: Float = target > current ? 0.010 : 0.115
            let coefficient = 1 - exp(-deltaTime / tau)
            smoothedBands[band] = current + (target - current) * coefficient
            peakBands[band] = max(peakBands[band] - deltaTime * 0.55, smoothedBands[band])
        }
    }

    private func meanBand(_ range: Range<Int>) -> Float {
        let values = range.clamped(to: 0..<bandCount)
        guard !values.isEmpty else { return 0 }
        var sum: Float = 0
        for index in values { sum += smoothedBands[index] }
        return sum / Float(values.count)
    }

    private func spectralCentroid() -> Float {
        var weighted: Float = 0
        var total: Float = 0
        for band in 0..<bandCount {
            let weight = smoothedBands[band]
            weighted += weight * Float(band) / Float(bandCount - 1)
            total += weight
        }
        return total > 1e-5 ? weighted / total : 0.5
    }

    // MARK: - 节拍

    private func updateBeat(deltaTime: Float) {
        var flux: Float = 0
        for band in 2..<min(48, bandCount) {
            flux += max(0, smoothedBands[band] - previousBands[band])
        }
        previousBands = smoothedBands

        beatFluxHistory.append(flux)
        if beatFluxHistory.count > 43 { beatFluxHistory.removeFirst(beatFluxHistory.count - 43) }
        let mean = beatFluxHistory.reduce(0, +) / Float(max(1, beatFluxHistory.count))
        var variance: Float = 0
        for value in beatFluxHistory { variance += (value - mean) * (value - mean) }
        variance /= Float(max(1, beatFluxHistory.count))
        let threshold = mean + 1.4 * sqrt(variance) + 0.002

        let now = CACurrentMediaTime()
        if flux > threshold, now - lastBeatTime > 0.18, flux > 0.004 {
            lastBeatTime = now
            beatPulse = 1
        }
        beatPulse = max(0, beatPulse - deltaTime * 2.2)

        if levelFromRMS() < 0.02 {
            silenceDuration += TimeInterval(deltaTime)
        } else {
            silenceDuration = 0
        }
    }
}
