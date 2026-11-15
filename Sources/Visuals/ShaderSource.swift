//
//  ShaderSource.swift
//  Lyrascope
//
//  Metal 着色器的全部源码。刻意以字符串形式内嵌、在运行时编译：
//    · 不依赖 .metal 文件与离线 Metal 工具链（Xcode 26 起 Metal 编译器需单独下载）
//    · 方便在 --selftest 里直接验证 GLSL/Metal 语法
//  所有着色器代码均为本项目原创（SDF / 值噪声 / 频谱映射的常规写法），无第三方来源。
//

import Foundation

enum ShaderSource {

    static let metal: String = #"""
#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265359;
constant int kBandCount = 96;
constant int kOffBandf = 32;
constant int kOffPeak = 128;
constant int kOffWave = 224;
constant int kOffScope = 480;
constant int kWaveCount = 256;
constant int kScopeCount = 192;

// uniform 布局（float 下标）
constant int U_TIME = 0;
constant int U_DT = 1;
constant int U_WIDTH = 2;
constant int U_HEIGHT = 3;
constant int U_BASS = 4;
constant int U_MID = 5;
constant int U_TREBLE = 6;
constant int U_LEVEL = 7;
constant int U_LUFS = 8;
constant int U_BEAT = 9;
constant int U_CENTROID = 10;
constant int U_PEAK = 11;
constant int U_CORR = 12;
constant int U_SILENT = 13;
constant int U_MODE = 14;
constant int U_BLOOM = 15;
constant int U_DIM = 16;
constant int U_PALETTE = 18;
constant int U_SCROLL = 19;
constant int U_BEATAGE = 20;
constant int U_NORM = 17;   // 由 CPU 每帧算出的频段归一化系数
constant int U_ASPECT = 21;

// ---------------------------------------------------------------- utility

float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm2(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; ++i) {
        value += amplitude * vnoise(p);
        p *= 2.03;
        amplitude *= 0.5;
    }
    return value;
}

/// smoothstep 要求 e0 < e1；这里包一层「反向」版本，避免写错参数顺序导致未定义行为。
float invSmooth(float e0, float e1, float x) {
    return 1.0 - smoothstep(e0, e1, x);
}

float3 palA(int index) {
    if (index == 1) { return float3(1.00, 0.78, 0.34); }
    if (index == 2) { return float3(0.55, 0.80, 1.00); }
    if (index == 3) { return float3(0.90, 0.90, 0.93); }
    return float3(0.20, 0.95, 0.85);
}

float3 palB(int index) {
    if (index == 1) { return float3(1.00, 0.55, 0.18); }
    if (index == 2) { return float3(0.30, 0.50, 1.00); }
    if (index == 3) { return float3(0.62, 0.64, 0.70); }
    return float3(0.55, 0.45, 1.00);
}

float3 palC(int index) {
    if (index == 1) { return float3(0.98, 0.92, 0.62); }
    if (index == 2) { return float3(0.86, 0.96, 1.00); }
    if (index == 3) { return float3(1.00, 1.00, 1.00); }
    return float3(1.00, 0.35, 0.75);
}

float sampleBand(constant float *u, float x) {
    float position = clamp(x, 0.0, 1.0) * float(kBandCount - 1);
    int index = int(position);
    float fraction = position - float(index);
    float a = u[kOffBandf + min(index, kBandCount - 1)];
    float b = u[kOffBandf + min(index + 1, kBandCount - 1)];
    return mix(a, b, fraction);
}

float samplePeak(constant float *u, float x) {
    float position = clamp(x, 0.0, 1.0) * float(kBandCount - 1);
    int index = int(position);
    float fraction = position - float(index);
    float a = u[kOffPeak + min(index, kBandCount - 1)];
    float b = u[kOffPeak + min(index + 1, kBandCount - 1)];
    return mix(a, b, fraction);
}

/// 频段值的自动增益：以当前帧最响的频段为 0.9 的参考，避免响度过高时柱子全部顶格。
// 频段值已在 CPU 侧做过「去中位数」的对比度处理，这里只做归一化与裁切。
float bandNorm(constant float *u, float x) {
    float normalizer = max(0.35, u[U_NORM]);
    return clamp(sampleBand(u, x) / normalizer, 0.0, 1.0);
}

float peakNorm(constant float *u, float x) {
    float normalizer = max(0.35, u[U_NORM]);
    return clamp(samplePeak(u, x) / normalizer, 0.0, 1.0);
}

float sampleWave(constant float *u, float x) {
    float position = clamp(x, 0.0, 1.0) * float(kWaveCount - 1);
    int index = int(position);
    float fraction = position - float(index);
    float a = u[kOffWave + min(index, kWaveCount - 1)];
    float b = u[kOffWave + min(index + 1, kWaveCount - 1)];
    return mix(a, b, fraction);
}

// ---------------------------------------------------------------- aurora

float3 renderAurora(float2 uv, constant float *u) {
    float time = u[U_TIME];
    float aspect = u[U_ASPECT];
    int palette = int(u[U_PALETTE] + 0.5);
    float level = u[U_LEVEL];
    float bass = u[U_BASS];
    float beat = u[U_BEAT];
    float bloom = u[U_BLOOM];

    float3 colorA = palA(palette);
    float3 colorB = palB(palette);
    float3 colorC = palC(palette);

    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float radius = length(p);
    float angle = atan2(p.y, p.x);
    float angle01 = fract(angle / (2.0 * PI) + 0.25);
    float mirrored = angle01 < 0.5 ? angle01 * 2.0 : (1.0 - angle01) * 2.0;

    // 底色：极深的午夜蓝，中心微微透亮
    float3 color = mix(float3(0.003, 0.004, 0.011), float3(0.013, 0.009, 0.034), smoothstep(-0.7, 0.8, p.y));

    // 星云：低对比的彩雾，让纯黑背景不至于死板
    float nebulaNoise = fbm2(uv * float2(aspect, 1.0) * 2.6 + float2(time * 0.018, -time * 0.012));
    color += mix(colorB, colorC, 0.55) * (nebulaNoise - 0.48) * 0.030 * (0.6 + level);

    // 中心呼吸光：低频越强，光晕越宽
    float centerGlow = exp(-radius * radius / (0.085 + 0.05 * bass));
    color += mix(colorA, colorB, 0.42) * centerGlow * (0.010 + 0.028 * level + 0.014 * beat);

    // 极光帘幕：三条错落的丝带，被垂直光柱切成细密的褶皱
    for (int i = 0; i < 3; ++i) {
        float layer = float(i);
        float baseY = 0.26 - layer * 0.15;
        float x = p.x;
        float bandValue = bandNorm(u, clamp(abs(x) * 1.15, 0.0, 1.0));
        float noise = fbm2(float2(x * 1.15 + layer * 7.0, time * 0.13 + layer * 2.0));
        float wave = baseY + (noise - 0.5) * 0.26 + 0.045 * sin(x * 1.6 + time * (0.30 + 0.07 * layer) + layer * 1.9);
        float offset = p.y - wave;
        float thickness = 0.055 + 0.030 * bandValue + 0.012 * sin(time * 0.5 + layer);
        float body = exp(-(offset * offset) / (thickness * thickness));
        float veil = exp(-(offset * offset) / (thickness * thickness * 12.0));
        float shaft = 0.22 + 0.78 * pow(vnoise(float2(x * 9.0 + layer * 17.0, time * 0.22 + layer * 5.0)), 1.5);
        float weight = (body * 0.30 + veil * 0.03) * shaft * (0.18 + 0.40 * level + 0.26 * bandValue);
        float3 tint = mix(mix(colorA, colorB, fract(layer * 0.31 + 0.15)), colorC,
                          0.18 + 0.20 * sin(time * 0.15 + layer * 1.3));
        tint = mix(float3(dot(tint, float3(0.299, 0.587, 0.114))), tint, 1.9);
        color += tint * weight * (0.55 + 0.85 * bloom);
    }

    // 频谱日冕：96 根沿圆周镜像对称的细柱
    float coronaInner = 0.325 + 0.010 * sin(time * 0.8);
    float barSpace = mirrored * float(kBandCount);
    int barIndex = int(barSpace);
    float barFrac = fract(barSpace);
    float bandValue = bandNorm(u, (float(barIndex) + 0.5) / float(kBandCount));
    float peakValue = peakNorm(u, (float(barIndex) + 0.5) / float(kBandCount));
    float barGap = smoothstep(0.0, 0.48, barFrac) * smoothstep(0.0, 0.48, 1.0 - barFrac);
    float barGapWide = smoothstep(0.0, 0.16, barFrac) * smoothstep(0.0, 0.16, 1.0 - barFrac);
    float barOuter = coronaInner + 0.004 + bandValue * 0.098;
    float barMask = step(coronaInner, radius) * step(radius, barOuter);
    float3 barTint = mix(colorA, colorB, mirrored);
    barTint = mix(barTint, colorC, 0.26);
    // 提纯：把柱子的色度拉开，否则 mint→violet 的中点会混成灰蓝
    barTint = mix(float3(dot(barTint, float3(0.299, 0.587, 0.114))), barTint, 2.3);
    float barFade = 1.0 - 0.55 * smoothstep(0.0, 0.30, (radius - coronaInner) / 0.24);
    // 用 mix 而不是纯叠加：低亮度时也能保住柱子的色相，不会糊成灰白
    float fanAlpha = barMask * barGapWide * barFade * (0.10 + 0.16 * bandValue);
    color = mix(color, barTint * 1.25, clamp(fanAlpha, 0.0, 0.85));
    float barAlpha = barMask * barGap * barFade * (0.34 + 0.48 * bandValue);
    color = mix(color, barTint * (1.15 + 0.55 * bandValue), clamp(barAlpha, 0.0, 0.92));

    // 柱顶亮缘：和柱子连在一起，不单独浮在外面（否则所有柱子等长时会变成一圈虚线）
    float capValue = min(peakValue, bandValue + 0.10);
    float tipStart = max(coronaInner, barOuter - 0.0052);
    float cap = step(tipStart, radius) * step(radius, barOuter + 0.0010) * barGap;
    color = mix(color, barTint * 2.15, cap * (0.30 + 0.30 * capValue));

    // 峰值提示：只有明显高过柱顶时才画一根很淡的细线
    float peakLift = peakValue - bandValue;
    float peakOuter = coronaInner + 0.004 + peakValue * 0.098;
    float peakTick = step(peakOuter, radius) * step(radius, peakOuter + 0.0022)
                   * barGap * smoothstep(0.12, 0.34, peakLift);
    color = mix(color, barTint * 1.7, peakTick * 0.28);

    // 环基线 + 内侧玻璃沿
    float baseRing = exp(-abs(radius - coronaInner) * 240.0);
    color += mix(colorA, colorC, 0.45) * baseRing * (0.24 + 0.42 * level + 0.35 * beat);
    float inner = abs(radius - 0.300);
    color += colorA * exp(-inner * inner / 0.000035) * (0.06 + 0.16 * level);

    // 星尘
    float2 starGrid = uv * float2(aspect, 1.0) * 120.0;
    float2 starCell = floor(starGrid);
    float2 starOffset = fract(starGrid) - 0.5;
    float starHash = hash21(starCell);
    float star = (1.0 - smoothstep(0.0, 0.40, length(starOffset))) * step(0.994, starHash);
    float twinkle = 0.55 + 0.45 * sin(time * 2.6 + starHash * 61.0);
    color += float3(0.72, 0.80, 1.0) * star * twinkle * (0.16 + 0.32 * level);

    // 暗角
    float vignette = 1.0 - smoothstep(0.20, 1.22, length(p * float2(0.92, 1.02)));
    color *= mix(0.25, 1.0, vignette);

    // 抖动噪声，避免大面积渐变出现色带
    float grain = (hash21(uv * float2(u[U_WIDTH], u[U_HEIGHT]) + time * 0.37) - 0.5) * 0.016;
    color += grain;

    return color;
}

// ---------------------------------------------------------------- studio

float3 heatMap(float value) {
    float3 c0 = float3(0.015, 0.020, 0.045);
    float3 c1 = float3(0.035, 0.155, 0.360);
    float3 c2 = float3(0.090, 0.520, 0.520);
    float3 c3 = float3(0.660, 0.560, 0.300);
    float3 c4 = float3(0.950, 0.420, 0.330);
    float t = clamp(value, 0.0, 1.0);
    if (t < 0.25) { return mix(c0, c1, t / 0.25); }
    if (t < 0.50) { return mix(c1, c2, (t - 0.25) / 0.25); }
    if (t < 0.75) { return mix(c2, c3, (t - 0.50) / 0.25); }
    return mix(c3, c4, (t - 0.75) / 0.25);
}

float3 renderStudio(float2 uv, constant float *u, texture2d<float> history, sampler histSampler) {
    float time = u[U_TIME];
    int palette = int(u[U_PALETTE] + 0.5);
    float level = u[U_LEVEL];
    float lufs = u[U_LUFS];
    float peak = u[U_PEAK];
    float correlation = u[U_CORR];

    float3 accent = palA(palette);
    float3 secondary = palB(palette);

    // 统一用 v = 0 在底部，避免 uv 的 y 方向跟视觉直觉反着来。
    float v = 1.0 - uv.y;

    // 背景：炭黑 + 极细网格
    float3 color = float3(0.014, 0.016, 0.021);
    float2 gridPosition = float2(uv.x * 28.0, v * 16.0);
    float2 gridLine = abs(fract(gridPosition) - 0.5);
    float grid = smoothstep(0.485, 0.5, max(gridLine.x, gridLine.y));
    color += float3(0.055, 0.062, 0.078) * grid * 0.30;

    // ---------------- 上部：频谱瀑布 ----------------
    float waterfallBottom = 0.545;
    float waterfallTop = 0.965;
    if (v > waterfallBottom && v < waterfallTop) {
        float localY = (v - waterfallBottom) / (waterfallTop - waterfallBottom);
        float scroll = u[U_SCROLL];
        float textureValue = history.sample(histSampler, float2(fract(uv.x + scroll), clamp(localY, 0.0, 1.0))).r;
        float shaped = pow(clamp(textureValue, 0.0, 1.0), 1.25);
        float3 heat = heatMap(shaped) * 0.82;
        float fade = smoothstep(0.0, 0.06, localY) * smoothstep(0.0, 0.10, 1.0 - localY);
        color = mix(color, heat, 0.70 * fade);
        // 瀑布上压一层细网格，保留仪表质感
        color = mix(color, color * 1.35 + float3(0.02, 0.024, 0.03), grid * 0.35);
    }

    // 分界线
    float divider = (v - waterfallBottom) / 0.0016;
    color += accent * exp(-divider * divider) * 0.45;

    // ---------------- 下部：柱状频谱 ----------------
    float barBase = 0.045;
    float barTop = 0.455;
    if (v > barBase - 0.02 && v < barTop + 0.02) {
        float t = clamp((v - barBase) / (barTop - barBase), 0.0, 1.0);
        float index = floor(uv.x * float(kBandCount));
        float local = fract(uv.x * float(kBandCount));
        float gap = smoothstep(0.0, 0.30, local) * smoothstep(0.0, 0.30, 1.0 - local);
        float bandValue = bandNorm(u, (index + 0.5) / float(kBandCount));
        float peakValue = peakNorm(u, (index + 0.5) / float(kBandCount));
        float barHeight = 0.015 + bandValue * (barTop - barBase);
        float bar = step(v - barBase, barHeight) * gap;
        float3 barColor = mix(accent, secondary, t);
        barColor = mix(float3(dot(barColor, float3(0.299, 0.587, 0.114))), barColor, 2.0);
        // 每根柱子自己从底到顶做渐变：底暗顶亮，避免所有柱子贴底连成一堵实心墙
        float rel = clamp((v - barBase) / max(barHeight, 0.001), 0.0, 1.0);
        float barFill = bar * pow(rel, 0.85) * 0.82;
        float3 barShade = barColor * (0.55 + 0.75 * rel);
        color = mix(color, barShade, clamp(barFill, 0.0, 0.92));

        // 柱顶亮线
        float tip = exp(-abs((v - barBase) - barHeight) * 220.0) * gap;
        color += mix(float3(1.0), secondary, 0.45) * tip * 0.55;

        // 峰值帽
        float capHeight = 0.015 + peakValue * (barTop - barBase);
        float cap = exp(-abs((v - barBase) - capHeight) * 340.0) * gap;
        color += float3(0.98, 0.92, 0.86) * cap * 0.55;

        // 水平刻度
        float ticks = abs(fract(t * 4.0) - 0.5);
        color += float3(0.30, 0.34, 0.42) * smoothstep(0.492, 0.5, ticks) * 0.16 * gap;
    }

    // ---------------- 示波器 ----------------
    float scopeBaseline = 0.30;
    float wave = sampleWave(u, uv.x);
    float waveCurve = scopeBaseline + wave * 0.115;
    float waveDistance = abs(v - waveCurve);
    float waveWidth = 0.0014 + 0.0012 * level;
    float waveCore = exp(-waveDistance * waveDistance / (waveWidth * waveWidth));
    color += mix(float3(0.90, 0.98, 1.0), accent, 0.35) * waveCore * (0.55 + 0.55 * level);
    color += accent * exp(-waveDistance / 0.012) * 0.07;

    // ---------------- 声像仪（右上） ----------------
    float2 scopeCenter = float2(0.845, 0.845);
    float2 scopeUV = (float2(uv.x, v) - scopeCenter) * float2(u[U_ASPECT], 1.0);
    float scopeRadius = 0.095;
    float scopeDistance = length(scopeUV);
    if (scopeDistance < scopeRadius + 0.03) {
        float ring = exp(-abs(scopeDistance - scopeRadius) * 420.0);
        color += float3(0.55, 0.62, 0.78) * ring * 0.30;
        float axis = max(1.0 - smoothstep(0.0, 0.0012, abs(scopeUV.x)),
                         1.0 - smoothstep(0.0, 0.0012, abs(scopeUV.y)));
        color += float3(0.32, 0.37, 0.48) * axis * 0.22;
        for (int i = 0; i < 48; ++i) {
            float fi = float(i) / 48.0;
            float2 point = float2(u[kOffScope + i * 2], u[kOffScope + i * 2 + 1]);
            float2 rotated = float2(point.x - point.y, point.x + point.y) * 0.70710678;
            float2 target = rotated * scopeRadius * 0.88;
            float distanceToPoint = length(scopeUV - target);
            float pointGlow = exp(-distanceToPoint * distanceToPoint / 0.00005);
            color += mix(accent, float3(1.0), fi * 0.6) * pointGlow * 0.45;
        }
        color += float3(0.90, 0.95, 1.0) * exp(-scopeDistance * scopeDistance / 0.000015) * (0.12 + 0.22 * max(correlation, 0.0));
    }

    // ---------------- LUFS 电平条（右侧） ----------------
    float meterMin = 0.055;
    float meterMax = 0.505;
    if (uv.x > 0.945 && uv.x < 0.962) {
        float local = (uv.x - 0.945) / 0.017;
        float frame = smoothstep(0.0, 0.25, local) * smoothstep(0.0, 0.25, 1.0 - local);
        float lufsNorm = clamp((lufs + 42.0) / 42.0, 0.0, 1.0);
        float fillY = mix(meterMin, meterMax, lufsNorm);
        float filled = step(v, fillY) * step(meterMin, v);
        float3 meterColor = lufsNorm > 0.92 ? float3(1.0, 0.36, 0.32)
                          : (lufsNorm > 0.80 ? float3(1.0, 0.80, 0.36) : accent);
        color = mix(color, meterColor * 0.85, filled * frame * 0.75);
        color += float3(0.22, 0.25, 0.32) * frame * 0.25;
        // -14 LUFS 目标线
        float targetY = mix(meterMin, meterMax, clamp((-14.0 + 42.0) / 42.0, 0.0, 1.0));
        float targetDistance = (v - targetY) / 0.0016;
        color += float3(0.55, 0.95, 0.75) * exp(-targetDistance * targetDistance) * 0.45 * frame;
    }

    // 削波提示
    if (peak > 0.995) {
        color += float3(1.0, 0.25, 0.22) * 0.06;
    }

    // 暗角
    float vignette = 1.0 - smoothstep(0.40, 1.30, length((float2(uv.x, v) - 0.5) * float2(u[U_ASPECT] * 0.8, 1.0)));
    color *= mix(0.62, 1.0, vignette);

    float grain = (hash21(uv * float2(u[U_WIDTH], u[U_HEIGHT]) + time * 0.31) - 0.5) * 0.010;
    color += grain;

    return color;
}

// ---------------------------------------------------------------- 入口

// ---------------------------------------------------------------- prism（棱镜隧道）

float3 renderPrism(float2 uv, constant float *u) {
    float time = u[U_TIME];
    float aspect = u[U_ASPECT];
    int palette = int(u[U_PALETTE] + 0.5);
    float level = u[U_LEVEL];
    float bass = u[U_BASS];
    float treble = u[U_TREBLE];
    float beat = u[U_BEAT];

    float3 colorA = palA(palette);
    float3 colorB = palB(palette);
    float3 colorC = palC(palette);
    float3 accent = mix(colorA, float3(0.88, 0.97, 1.00), 0.50);

    float2 p = (uv - float2(0.5)) * float2(aspect, 1.0);
    float radius = length(p);
    float angle = atan2(p.y, p.x) / (2.0 * PI) + 0.5;   // 0..1

    // 底色：中心偏亮，四周几乎全黑
    float3 color = mix(float3(0.030, 0.026, 0.060),
                       float3(0.002, 0.003, 0.010),
                       smoothstep(0.0, 0.95, radius));

    // 星尘
    float2 starGrid = uv * float2(220.0, 160.0);
    float2 starOffset = fract(starGrid) - 0.5;
    float star = step(0.9974, hash21(floor(starGrid))) * smoothstep(0.34, 0.0, length(starOffset));
    color += float3(0.85, 0.90, 1.00) * star * (0.10 + 0.26 * level) * smoothstep(0.10, 0.70, radius);

    // 隧道环：深度与半径成反比，越靠中心越远
    float depth = 1.0 / max(radius, 0.045);
    float speed = 0.45 + 1.10 * level + 0.45 * beat;
    float phase = depth * 0.62 - time * speed;
    float cell = fract(phase);
    float edge = 1.0 - abs(cell * 2.0 - 1.0);           // 0 环心，1 环边
    float ring = pow(edge, 34.0);
    float ringGlow = pow(edge, 6.0) * 0.045;

    float mirrored = 1.0 - abs(2.0 * angle - 1.0);
    float bandValue = bandNorm(u, mirrored);
    float3 tint = mix(colorA, colorB, mirrored);
    // 让环的颜色随深度缓慢漂移，隧道才有「往里走」的感觉
    float depthTint = fract(phase * 0.22);
    tint = mix(tint, accent, 0.18 + 0.30 * depthTint);
    float centerFade = mix(0.10, 1.0, smoothstep(0.03, 0.26, radius));
    float ringGain = (0.25 + 1.05 * bandValue) * (0.35 + 0.85 * level) * centerFade;
    color += tint * (ring * 1.05 + ringGlow) * ringGain * smoothstep(0.05, 0.22, radius);

    // 辐条：96 根从中心发散的光带
    float spokes = float(kBandCount);
    float spokeCoord = fract(angle * spokes);
    float spokeDistance = abs(spokeCoord - 0.5) * 2.0;
    float spoke = 1.0 - smoothstep(0.05, 0.45, spokeDistance);
    float spokeBand = bandNorm(u, mirrored);
    float depthFade = smoothstep(0.06, 0.62, radius);
    color += mix(colorA, colorB, mirrored) * spoke * spokeBand * depthFade * (0.05 + 0.16 * level);

    // 中心光核
    float core = exp(-radius * radius * 900.0);
    color += mix(accent, float3(1.0), 0.35) * core * (0.35 + 0.65 * bass + 0.40 * beat);
    color += mix(accent, float3(1.0), 0.15) * exp(-radius * radius * 60.0) * 0.10 * (0.5 + 0.5 * level);

    // 雾：远处的环融进背景
    float mist = fbm2(float2(angle * 7.0, depth * 0.25 - time * 0.12));
    color += tint * mist * 0.025 * smoothstep(0.10, 1.10, radius);

    // 高频闪烁
    color += accent * treble * ring * 0.15;

    float vignette = invSmooth(0.25, 1.35, radius);
    color *= mix(0.55, 1.0, vignette);

    float grain = hash21(uv * float2(1920.0, 1080.0) + time * 37.0) - 0.5;
    color += grain * 0.012;
    return color;
}

// ---------------------------------------------------------------- ripple（水面涟漪）

float3 renderRipple(float2 uv, constant float *u) {
    float time = u[U_TIME];
    float aspect = u[U_ASPECT];
    int palette = int(u[U_PALETTE] + 0.5);
    float level = u[U_LEVEL];
    float bass = u[U_BASS];
    float beat = u[U_BEAT];

    float3 colorA = palA(palette);
    float3 colorB = palB(palette);
    float3 colorC = palC(palette);
    float3 accent = mix(colorA, float3(0.88, 0.97, 1.00), 0.50);

    float2 p = (uv - float2(0.5)) * float2(aspect, 1.0);
    float radius = length(p) + 0.0001;
    float angle = atan2(p.y, p.x);

    // 三条不同频率的同心波叠加成水面高度
    float k1 = 16.0, k2 = 27.0, k3 = 41.0;
    float t1 = radius * k1 - time * 2.10;
    float t2 = radius * k2 - time * 2.90 + 1.7;
    float t3 = radius * k3 - time * 3.70 + 3.1;
    float amp = 0.30 + 0.35 * level + 0.15 * beat;
    float height = (sin(t1) * 0.52 + sin(t2) * 0.30 + sin(t3) * 0.18) * amp;

    // 解析导数，用来算法线
    float slope = (cos(t1) * k1 * 0.52 + cos(t2) * k2 * 0.30 + cos(t3) * k3 * 0.18) * amp;
    float2 direction = p / radius;
    float3 normal = normalize(float3(-slope * direction.x * 0.010,
                                     -slope * direction.y * 0.010,
                                     1.0));

    float3 viewDir = normalize(float3(direction.x * 0.25, direction.y * 0.25, 1.0));
    float3 lightDir = normalize(float3(-0.35, 0.55, 0.75));
    float fresnel = pow(1.0 - saturate(dot(normal, viewDir)), 3.0);
    float specular = pow(saturate(dot(reflect(-lightDir, normal), viewDir)), 90.0);

    // 深色水面 + 波峰高光：整屏泛白是因为所有项都在做加法，这里只让波峰亮起来
    float3 water = mix(float3(0.001, 0.004, 0.012), float3(0.005, 0.017, 0.034), invSmooth(0.0, 0.95, radius));
    float crest = smoothstep(0.42, 0.88, height);
    float trough = smoothstep(-0.42, -0.88, height);
    trough *= 0.0;
    float3 color = water;
    // 波峰只用极轻的一层，避免整屏糊成一块白
    color += mix(colorA, accent, 0.30) * crest * (0.015 + 0.045 * level);
    color += mix(colorA, accent, 0.25) * fresnel * 0.06;
    color += accent * specular * (0.10 + 0.20 * level);

    // 细密的水光纹路
    float caustic = pow(abs(sin(radius * 90.0 - time * 2.6)), 12.0);
    color += colorA * caustic * 0.05 * smoothstep(0.0, 0.5, level);

    // 频谱环：把频谱画成水面上的一圈光带
    float ringRadius = 0.30 + 0.04 * sin(time * 0.7);
    float angleUnit = clamp(angle / (2.0 * PI) + 0.5, 0.0, 1.0);
    float mirroredUnit = 1.0 - abs(2.0 * angleUnit - 1.0);
    float bandValue = bandNorm(u, mirroredUnit);
    float ringDistance = abs(radius - ringRadius);
    float ring = exp(-ringDistance * ringDistance * 5000.0);
    color += mix(colorA, accent, 0.30) * ring * (0.10 + 0.90 * bandValue) * 0.20;

    // 从中心荡开的节拍涟漪
    float pulseRadius = 0.10 + fract(time * 0.55) * 1.20;
    float pulse = exp(-pow(abs(radius - pulseRadius) * 34.0, 2.0)) * (1.0 - fract(time * 0.55));
    color += accent * pulse * (0.05 + 0.22 * beat);

    // 水面反光点
    float2 sparkleGrid = uv * float2(640.0, 400.0);
    float2 sparkleOffset = fract(sparkleGrid) - 0.5;
    float sparkle = step(0.9986, hash21(floor(sparkleGrid) + floor(time * 3.0)));
    color += float3(0.80, 0.95, 1.00) * sparkle * smoothstep(0.30, 0.0, length(sparkleOffset)) * (0.20 + 0.55 * level);

    float vignette = invSmooth(0.30, 1.30, radius);
    color *= mix(0.62, 1.0, vignette);
    float grain = hash21(uv * float2(1720.0, 980.0) + time * 29.0) - 0.5;
    color += grain * 0.010;
    return color;
}

// ---------------------------------------------------------------- ridge（声波山脉）

float3 renderRidge(float2 uv, constant float *u) {
    float time = u[U_TIME];
    float aspect = u[U_ASPECT];
    int palette = int(u[U_PALETTE] + 0.5);
    float level = u[U_LEVEL];
    float bass = u[U_BASS];
    float beat = u[U_BEAT];

    float3 colorA = palA(palette);
    float3 colorB = palB(palette);
    float3 colorC = palC(palette);

    float v = 1.0 - uv.y;   // 0 在底部

    // 天空
    float3 skyLow = mix(float3(0.020, 0.016, 0.040), colorB * 0.14, 0.55);
    float3 skyHigh = float3(0.002, 0.003, 0.010);
    float3 color = mix(skyLow, skyHigh, smoothstep(0.0, 1.0, v));

    // 星尘
    float2 starGrid = uv * float2(260.0, 180.0);
    float2 starOffset = fract(starGrid) - 0.5;
    float star = step(0.9978, hash21(floor(starGrid))) * smoothstep(0.32, 0.0, length(starOffset));
    color += float3(0.85, 0.90, 1.00) * star * (0.10 + 0.28 * level) * smoothstep(0.25, 0.95, v);

    // 落日
    float2 sunOffset = (uv - float2(0.5, 0.34)) * float2(aspect, 1.0);
    float sunDistance = length(sunOffset);
    float sunDisc = invSmooth(0.170, 0.180, sunDistance);
    float3 sunColor = mix(colorB, colorC, 0.45);
    color += sunColor * sunDisc * (0.30 + 0.45 * level);
    color += sunColor * exp(-sunDistance * 5.5) * 0.20 * (0.60 + 0.60 * level);

    // 太阳上的横向扫条纹
    float stripe = smoothstep(0.42, 0.50, fract(uv.y * 34.0 + time * 0.05));
    color *= mix(1.0, 1.0 - stripe * 0.55, sunDisc);

    // 四层山脊，从远到近叠上去
    for (int i = 0; i < 4; ++i) {
        float index = float(i);
        float depth = 1.0 - index / 4.0;                       // 1 远、0.25 近
        float baseLine = 0.10 + 0.16 * depth;
        float scroll = time * (0.010 + 0.020 * (1.0 - depth)) + index * 0.41;
        float x = uv.x * (1.0 + index * 0.35) + scroll;
        float waveSample = (sampleWave(u, fract(x * 0.75)) +
                            sampleWave(u, fract(x * 0.75 + 0.004)) +
                            sampleWave(u, fract(x * 0.75 - 0.004))) / 3.0;
        float wave = waveSample * 2.0 - 1.0;
        float ridgeNoise = fbm2(float2(x * 2.4 + index * 5.3, index * 1.7)) - 0.5;
        float localLevel = level * (0.55 + 0.45 * depth);
        float profile = baseLine + wave * (0.020 + 0.070 * localLevel) + ridgeNoise * 0.050;
        profile = max(profile, 0.02);

        float inside = invSmooth(profile - 0.004, profile + 0.002, v);
        float3 layerColor = mix(colorA, colorB, index / 4.0);
        layerColor = mix(layerColor, float3(0.012, 0.012, 0.025), (1.0 - depth) * 0.78);

        float bodyShade = mix(0.35, 1.0, saturate((profile - v) / max(profile, 0.01)));
        color = mix(color, layerColor * bodyShade * (0.38 + 0.42 * localLevel), inside);

        // 山脊亮线
        float ridgeLine = exp(-pow((v - profile) * 220.0, 2.0));
        color += mix(colorC, float3(1.0), 0.25) * ridgeLine * (0.45 + 0.85 * localLevel) * (0.40 + 0.60 * depth);
    }

    // 地平线辉光与低频底色
    color += colorB * exp(-pow((v - 0.30) * 12.0, 2.0)) * 0.10 * (0.5 + 0.8 * level);
    color += colorA * bass * 0.06 * smoothstep(0.0, 0.35, v) * invSmooth(0.35, 0.60, v);

    float2 centered = (uv - float2(0.5)) * float2(aspect, 1.0);
    float vignette = invSmooth(0.25, 1.25, length(centered));
    color *= mix(0.60, 1.0, vignette);
    color += colorC * beat * 0.02 * smoothstep(0.0, 0.5, v);
    float grain = hash21(uv * float2(1680.0, 960.0) + time * 31.0) - 0.5;
    color += grain * 0.010;
    return color;
}

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vs_fullscreen(uint vertexID [[vertex_id]]) {
    float2 p = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 fs_composite(VertexOut in [[stage_in]],
                             constant float *uniforms [[buffer(0)]],
                             texture2d<float> history [[texture(0)]]) {
    constexpr sampler histSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    int mode = int(uniforms[U_MODE] + 0.5);
    float3 color;
    if (mode == 1) {
        color = renderStudio(uv, uniforms, history, histSampler);
    } else if (mode == 2) {
        color = renderPrism(uv, uniforms);
    } else if (mode == 3) {
        color = renderRipple(uv, uniforms);
    } else if (mode == 4) {
        color = renderRidge(uv, uniforms);
    } else {
        color = renderAurora(uv, uniforms);
    }

    color *= 0.90;
    float dim = clamp(uniforms[U_DIM], 0.0, 1.0);
    color *= mix(1.0, 0.18, dim);

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, 1.45);

    // 线性空间 -> sRGB framebuffer 由硬件完成（.bgra8Unorm_srgb），
    // 这里只做一次柔和的 shoulder 抑制过曝，不再手动做 gamma，否则会被硬件二次提亮。
    color = color / (color + float3(0.80));

    return float4(color, 1.0);
}
"""#

    /// 星形/雪花等常量表不在这里，保持单文件便于审查。
    static let functionVertex = "vs_fullscreen"
    static let functionFragment = "fs_composite"
}
