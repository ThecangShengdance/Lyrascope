#!/usr/bin/env swift
//
//  make_icon.swift
//  Lyrascope
//
//  生成 AppIcon.appiconset 里的全部位图。纯 AppKit 绘制，无第三方依赖。
//  用法：swift scripts/make_icon.swift <输出目录>
//

import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Sources/Resources/Assets.xcassets/AppIcon.appiconset")

let canvas = 1024
let barCount = 72
let innerRadius: CGFloat = 236
let center = CGPoint(x: CGFloat(canvas) / 2, y: CGFloat(canvas) / 2)

func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
}

/// 每根柱子的长度：固定伪随机 + 一个低频包络，看起来像一段正在播放的频谱。
func barLength(_ index: Int) -> CGFloat {
    let t = CGFloat(index) / CGFloat(barCount)
    let envelope = 0.55 + 0.45 * sin(t * .pi * 1.35 + 0.4)
    let ripple = 0.42 + 0.58 * abs(sin(CGFloat(index) * 1.7 + 0.9))
    let jitter = 0.80 + 0.20 * abs(sin(CGFloat(index) * 4.3 + 2.1))
    return (34 + 168 * envelope * ripple * jitter)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("无法创建位图") }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无法创建绘图上下文") }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setAllowsAntialiasing(true)
    cg.scaleBy(x: CGFloat(size) / CGFloat(canvas), y: CGFloat(size) / CGFloat(canvas))

    // 底板：深色圆角矩形 + 冷色渐变
    let plate = NSRect(x: 56, y: 56, width: 912, height: 912)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 200, yRadius: 200)
    platePath.addClip()
    NSGradient(colors: [
        color(hue: 0.63, saturation: 0.68, brightness: 0.16),
        color(hue: 0.70, saturation: 0.80, brightness: 0.06),
        color(hue: 0.62, saturation: 0.55, brightness: 0.03)
    ])?.draw(in: plate, angle: -78)

    // 右上 / 左下两团极光
    func drawGlow(center: CGPoint, radius: CGFloat, hue: CGFloat, alpha: CGFloat) {
        let gradient = NSGradient(colorsAndLocations:
            (color(hue: hue, saturation: 0.85, brightness: 0.95, alpha: alpha), 0.0),
            (color(hue: hue, saturation: 0.85, brightness: 0.78, alpha: alpha * 0.40), 0.45),
            (color(hue: hue, saturation: 0.85, brightness: 0.66, alpha: alpha * 0.12), 0.78),
            (color(hue: hue, saturation: 0.85, brightness: 0.6, alpha: 0), 1.0)
        )
        gradient?.draw(in: NSBezierPath(ovalIn: NSRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )), relativeCenterPosition: .zero)
    }
    drawGlow(center: CGPoint(x: 760, y: 800), radius: 520, hue: 0.78, alpha: 0.42)
    drawGlow(center: CGPoint(x: 300, y: 260), radius: 520, hue: 0.48, alpha: 0.34)

    // 频谱环：先画三遍宽而淡的，再画一遍实心的，得到廉价的辉光
    func drawBars(lineWidth: CGFloat, alpha: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        for index in 0..<barCount {
            let angle = CGFloat(index) / CGFloat(barCount) * .pi * 2 - .pi / 2
            let length = barLength(index)
            let outer = innerRadius + length
            let start = CGPoint(
                x: center.x + cos(angle) * innerRadius,
                y: center.y + sin(angle) * innerRadius
            )
            let end = CGPoint(
                x: center.x + cos(angle) * outer,
                y: center.y + sin(angle) * outer
            )
            let hue = 0.47 + 0.30 * (0.5 + 0.5 * sin(angle * 1.1 + 0.9))
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            color(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha).setStroke()
            path.stroke()
        }
    }
    drawBars(lineWidth: 34, alpha: 0.05, saturation: 0.9, brightness: 1.0)
    drawBars(lineWidth: 22, alpha: 0.09, saturation: 0.9, brightness: 1.0)
    drawBars(lineWidth: 13, alpha: 0.95, saturation: 0.72, brightness: 1.0)

    // 内圈细环 + 高光
    let ring = NSBezierPath(ovalIn: NSRect(
        x: center.x - innerRadius + 16, y: center.y - innerRadius + 16,
        width: (innerRadius - 16) * 2, height: (innerRadius - 16) * 2
    ))
    ring.lineWidth = 5
    color(hue: 0.50, saturation: 0.45, brightness: 1.0, alpha: 0.55).setStroke()
    ring.stroke()

    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0)
    ])?.draw(in: NSBezierPath(ovalIn: NSRect(x: 210, y: 560, width: 420, height: 300)),
             relativeCenterPosition: .zero)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL, pixels: Int) -> Bool {
    let resized: NSBitmapImageRep
    if rep.pixelsWide == pixels {
        resized = rep
    } else {
        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        resized = target
    }
    guard let data = resized.representation(using: .png, properties: [:]) else { return false }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try data.write(to: url)
        return true
    } catch {
        return false
    }
}

let master = drawIcon(size: canvas)
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

var failures = 0
for (name, pixels) in variants {
    let url = outputDirectory.appendingPathComponent(name)
    if write(master, to: url, pixels: pixels) {
        print("✓ \(name) \(pixels)px")
    } else {
        print("✗ \(name)")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
