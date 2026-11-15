//
//  MetalVisualizer.swift
//  Lyrascope
//
//  Metal 渲染层：一个全屏三角形 + 一个片元着色器，把两种视觉风格都画在同一趟里。
//  着色器在运行时从字符串编译，见 ShaderSource.swift。
//

import Metal
import MetalKit
import SwiftUI
import os

// MARK: - 渲染配置

struct VisualConfig: Equatable {
    var mode: Int = 0          // 0 = 流光，1 = 制作人
    var palette: Int = 0       // 0 aurora / 1 gold / 2 ice / 3 mono
    var bloom: Float = 0.72
    var dim: Float = 0
    var normalizer: Float = 0.9

    static let uniformCount = 864
}

// MARK: - 引擎

/// 主线程上的帧中转站：分析器写入，渲染器与 SwiftUI 覆盖层读取。
final class VisualizerEngine {
    private(set) var frame: AudioFrame = .empty
    private(set) var config = VisualConfig()
    private(set) var beatAge: Float = 10

    func update(frame: AudioFrame, config: VisualConfig, beatAge: Float) {
        self.frame = frame
        self.config = config
        self.beatAge = beatAge
    }
}

// MARK: - 共享 Metal 资源

final class MetalSupport {

    final class Shared {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary
        let pipeline: MTLRenderPipelineState

        init?(device: MTLDevice) {
            guard let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            guard let library = try? device.makeLibrary(source: ShaderSource.metal, options: options) else {
                return nil
            }
            guard let vertex = library.makeFunction(name: ShaderSource.functionVertex),
                  let fragment = library.makeFunction(name: ShaderSource.functionFragment) else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
                return nil
            }

            self.device = device
            self.queue = queue
            self.library = library
            self.pipeline = pipeline
        }
    }

    static let shared: Shared? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let result = Shared(device: device)
        if result == nil {
            Logger(subsystem: "com.zhangzhouqi.Lyrascope", category: "metal")
                .error("Metal 渲染管线创建失败，将使用降级绘制。")
        }
        return result
    }()

    static var isAvailable: Bool { shared != nil }

    /// 供 --selftest 使用：确认着色器能在当前设备上编译。
    static func validateShaderCompilation() -> (Bool, String) {
        guard let device = MTLCreateSystemDefaultDevice() else { return (false, "没有可用的 Metal 设备") }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        do {
            let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
            let names = library.functionNames.sorted()
            let ok = names.contains(ShaderSource.functionVertex) && names.contains(ShaderSource.functionFragment)
            return (ok, "设备 \(device.name)，函数 \(names.joined(separator: ", "))")
        } catch {
            return (false, "\(error)")
        }
    }
}

// MARK: - 渲染器

final class MetalRenderer: NSObject, MTKViewDelegate {

    private let shared: MetalSupport.Shared
    private let uniformBuffer: MTLBuffer
    private let historyTexture: MTLTexture

    private var history: [Float16]
    private var uniforms: [Float]
    private var frameIndex: Int = 0

    private let historyWidth = 128
    private let historyHeight = AudioFrame.bandCount

    weak var engine: VisualizerEngine?

    init?(shared: MetalSupport.Shared, engine: VisualizerEngine) {
        guard let buffer = shared.device.makeBuffer(
            length: VisualConfig.uniformCount * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: historyWidth,
            height: historyHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = shared.device.makeTexture(descriptor: descriptor) else { return nil }

        self.shared = shared
        self.engine = engine
        self.uniformBuffer = buffer
        self.historyTexture = texture
        self.history = [Float16](repeating: 0, count: historyWidth * historyHeight)
        self.uniforms = [Float](repeating: 0, count: VisualConfig.uniformCount)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        (view as? PausableMTKView)?.noteDraw()
        guard let engine,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = shared.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        let frame = engine.frame
        fillUniforms(frame: frame, config: engine.config, beatAge: engine.beatAge, size: view.drawableSize)
        updateHistory(bands: frame.bands)

        encoder.setRenderPipelineState(shared.pipeline)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(historyTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameIndex &+= 1
    }

    // MARK: uniform 填充

    private func fillUniforms(frame: AudioFrame, config: VisualConfig, beatAge: Float, size: CGSize) {
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))

        uniforms[0] = Float(CACurrentMediaTime())
        uniforms[1] = Float(1.0 / 60.0)
        uniforms[2] = width
        uniforms[3] = height
        uniforms[4] = frame.bass
        uniforms[5] = frame.mid
        uniforms[6] = frame.treble
        uniforms[7] = frame.level
        uniforms[8] = frame.loudness
        uniforms[9] = frame.beat
        uniforms[10] = frame.centroid
        uniforms[11] = frame.peak
        uniforms[12] = frame.correlation
        uniforms[13] = frame.isSilent ? 1 : 0
        uniforms[14] = Float(config.mode)
        uniforms[15] = config.bloom
        uniforms[16] = config.dim
        uniforms[17] = config.normalizer
        uniforms[18] = Float(config.palette)
        uniforms[19] = 0
        uniforms[20] = beatAge
        uniforms[21] = width / height

        for index in 0..<AudioFrame.bandCount {
            uniforms[32 + index] = frame.bands[index]
            uniforms[128 + index] = frame.peaks[index]
        }
        for index in 0..<AudioFrame.waveformCount {
            uniforms[224 + index] = frame.waveform[index]
        }
        for index in 0..<AudioFrame.scopeCount {
            uniforms[480 + index * 2] = frame.scope[index].x
            uniforms[480 + index * 2 + 1] = frame.scope[index].y
        }

        uniforms.withUnsafeBytes { bytes in
            uniformBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    // MARK: 频谱瀑布历史

    private func updateHistory(bands: [Float]) {
        let rowCount = historyHeight
        history.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in 0..<rowCount {
                let rowPointer = base.advanced(by: row * historyWidth)
                memmove(rowPointer, rowPointer.advanced(by: 1), (historyWidth - 1) * MemoryLayout<Float16>.size)
                let value = row < bands.count ? Float16(max(0, min(1, bands[row]))) : 0
                rowPointer[historyWidth - 1] = value
            }
            historyTexture.replace(
                region: MTLRegionMake2D(0, 0, historyWidth, rowCount),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: historyWidth * MemoryLayout<Float16>.size
            )
        }
    }
}

// MARK: - 会被遮挡时自动暂停的 MTKView

/// 窗口被遮住、最小化或 App 隐藏时把渲染停掉：全屏 fragment shader 按 60 fps 跑
/// 很吃 GPU，看不见的时候没必要继续画。
final class PausableMTKView: MTKView {

    private var observers: [NSObjectProtocol] = []
    private var frameTimer: Timer?
    private var baseFPS: Int = 60
    private var suspended = false
    private var tickCounter = 0
    private(set) var drawCount = 0

    func noteDraw() {
        drawCount &+= 1
    }

    func setBaseFPS(_ fps: Int) {
        let clamped = max(1, fps)
        guard clamped != baseFPS else { return }
        baseFPS = clamped
        restartFrameTimer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        guard let window else {
            suspended = true
            return
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.updateSuspension()
            })
        }
        for name in [NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateSuspension()
            })
        }

        restartFrameTimer()
        updateSuspension()
    }

    /// 自己驱动重绘，不依赖 MTKView 的显示链路。
    ///
    /// MTKView 默认用一条挂在屏幕上的 display link 来驱动 draw；窗口 `close()` 再
    /// `orderFront()` 之后（窗口对象没换，只是重新上屏）这条链路不会自己恢复，
    /// 于是 `isPaused == false`、`preferredFramesPerSecond == 60`，看起来一切正常，
    /// 但 `draw` 再也不被调用，画面冻在最后一帧。
    /// 这里改成 `enableSetNeedsDisplay` + 自己的定时器，每次 tick 标记重绘，
    /// 由 AppKit 在下一个显示周期调用 draw，窗口怎么开关都不受影响。
    private func restartFrameTimer() {
        frameTimer?.invalidate()
        let interval = 1.0 / Double(max(1, baseFPS))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.onFrameTick()
        }
        timer.tolerance = interval * 0.10
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func onFrameTick() {
        guard !suspended else { return }
        tickCounter &+= 1
        // 完全被其它窗口盖住时降到约 1/8 帧率省电，但不停止绘制
        if let window, !window.occlusionState.contains(.visible), tickCounter % 8 != 0 {
            return
        }
        draw()
    }

    private func updateSuspension() {
        guard let window else {
            suspended = true
            return
        }
        let offscreen = !window.isVisible || window.isMiniaturized || NSApp.isHidden
        suspended = offscreen
        if !offscreen {
            draw()
        }
    }

    deinit {
        frameTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - SwiftUI 桥接

struct MetalVisualizerView: NSViewRepresentable {

    let engine: VisualizerEngine
    var preferredFPS: Int = 60

    final class Coordinator {
        var renderer: MetalRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = PausableMTKView(frame: .zero, device: MetalSupport.shared?.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.setBaseFPS(preferredFPS)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.layer?.isOpaque = true
        view.autoResizeDrawable = true

        if let shared = MetalSupport.shared {
            let renderer = MetalRenderer(shared: shared, engine: engine)
            renderer?.mtkView(view, drawableSizeWillChange: view.drawableSize)
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        (view as? PausableMTKView)?.setBaseFPS(preferredFPS)
    }
}

// MARK: - 降级绘制

/// 没有 Metal 时（极少数虚拟机环境）用 Canvas 画一个克制的替代品，保证界面不空。
struct FallbackVisualizer: View {

    let engine: VisualizerEngine
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let frame = engine.frame
                let level = CGFloat(frame.level)
                let bass = CGFloat(frame.bass)

                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.32

                var glow = context
                glow.addFilter(.blur(radius: 40 + 30 * level))
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                glow.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0.25, green: 0.85, blue: 0.80).opacity(0.55),
                            Color(red: 0.45, green: 0.35, blue: 0.95).opacity(0.30),
                            .clear
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius * 1.2
                    )
                )

                let count = 96
                for index in 0..<count {
                    let angle = Double(index) / Double(count) * Double.pi * 2 + time * 0.12
                    let value = CGFloat(frame.bands[index])
                    let inner = radius * (1.02 + 0.02 * sin(time + Double(index) * 0.1))
                    let outer = inner + radius * 0.12 + value * radius * 0.55 + bass * 12
                    let start = CGPoint(
                        x: center.x + cos(angle) * inner,
                        y: center.y + sin(angle) * inner
                    )
                    let end = CGPoint(
                        x: center.x + cos(angle) * outer,
                        y: center.y + sin(angle) * outer
                    )
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    let hue = 0.45 + 0.35 * Double(index) / Double(count)
                    context.stroke(
                        path,
                        with: .color(Color(hue: hue, saturation: 0.65, brightness: 1.0).opacity(0.25 + 0.55 * Double(value))),
                        lineWidth: max(1, size.width / 380)
                    )
                }
            }
        }
        .background(Color.black)
    }
}

// MARK: - 统一入口

struct VisualizerView: View {

    let engine: VisualizerEngine
    var preferredFPS: Int = 60

    var body: some View {
        Group {
            if MetalSupport.isAvailable {
                MetalVisualizerView(engine: engine, preferredFPS: preferredFPS)
            } else {
                FallbackVisualizer(engine: engine)
            }
        }
        .ignoresSafeArea()
    }
}
