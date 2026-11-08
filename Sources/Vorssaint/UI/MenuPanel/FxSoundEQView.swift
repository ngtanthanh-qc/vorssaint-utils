// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// FxSound-style audio enhancer & 9-band graphic equalizer panel integrated
/// into the Sound / Volume Mixer section.
struct FxSoundEQView: View {
    @ObservedObject private var eq = FxSoundEqualizerService.shared
    @State private var isExpanded = false
    @State private var selectedTab: Tab = .effects

    enum Tab: String, CaseIterable, Identifiable {
        case effects = "Effects"
        case graphicEQ = "9-Band EQ"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedTab) {
                            ForEach(Tab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)

                        Button {
                            eq.resetToPresetDefault()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reset to preset default")
                    }

                    if selectedTab == .effects {
                        effectsGrid
                    } else {
                        graphicEQSection
                    }
                }
                .padding(.top, 2)
                .opacity(eq.isEnabled ? 1.0 : 0.55)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(eq.isEnabled ? Color.accentColor : .secondary)

                    Text("FxSound EQ")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Picker("Preset", selection: Binding(
                get: { eq.preset },
                set: { eq.selectPreset($0) }
            )) {
                ForEach(FxSoundPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)

            Toggle("", isOn: $eq.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var effectsGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(FxSoundEffect.allCases) { effect in
                let level = eq.effects[effect] ?? 0
                HStack(spacing: 8) {
                    Image(systemName: effect.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(eq.isEnabled && level > 0 ? Color.accentColor : .secondary)
                        .frame(width: 14)

                    Text(effect.title)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 92, alignment: .leading)

                    Slider(
                        value: Binding(
                            get: { eq.effects[effect] ?? 0 },
                            set: { eq.setEffectLevel($0, for: effect) }
                        ),
                        in: 0...10,
                        step: 0.5
                    )
                    .controlSize(.small)

                    Text(level.truncatingRemainder(dividingBy: 1) == 0
                         ? "\(Int(level))"
                         : String(format: "%.1f", level))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
    }

    private var graphicEQSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            eqResponseCurve
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(FxSoundBand.allCases) { band in
                    let gain = band.rawValue < eq.bandGains.count ? eq.bandGains[band.rawValue] : 0
                    VStack(spacing: 3) {
                        Text(gain >= 0 ? "+\(Int(gain.rounded()))" : "\(Int(gain.rounded()))")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(abs(gain) > 0.1 ? .primary : .secondary)

                        VerticalEQBandSlider(
                            value: Binding(
                                get: { band.rawValue < eq.bandGains.count ? eq.bandGains[band.rawValue] : 0 },
                                set: { eq.setBandGain($0, for: band) }
                            ),
                            range: -12...12,
                            isActive: eq.isEnabled
                        )
                        .frame(width: 22, height: 84)

                        Text(band.shortLabel)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var eqResponseCurve: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2
            let gains = eq.bandGains
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: w, y: midY))
                }
                .stroke(Color.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { path in
                    guard !gains.isEmpty else { return }
                    let stepX = w / CGFloat(max(gains.count - 1, 1))
                    for (idx, gain) in gains.enumerated() {
                        let x = CGFloat(idx) * stepX
                        let normalized = CGFloat(min(max(gain, -12), 12) / 12.0)
                        let y = midY - normalized * (midY - 5)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            let prevX = CGFloat(idx - 1) * stepX
                            let prevNorm = CGFloat(min(max(gains[idx - 1], -12), 12) / 12.0)
                            let prevY = midY - prevNorm * (midY - 5)
                            let midX = (prevX + x) * 0.5
                            path.addCurve(to: CGPoint(x: x, y: y),
                                          control1: CGPoint(x: midX, y: prevY),
                                          control2: CGPoint(x: midX, y: y))
                        }
                    }
                }
                .stroke(eq.isEnabled ? Color.accentColor : Color.secondary, lineWidth: 1.8)
            }
        }
    }
}

private struct VerticalEQBandSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let height = max(geo.size.height, 1)
            let span = range.upperBound - range.lowerBound
            let normalized = (value - range.lowerBound) / span
            let thumbY = height * (1.0 - CGFloat(min(max(normalized, 0), 1)))
            let centerY = height * 0.5

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 4)

                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 10, height: 1)
                    .position(x: geo.size.width / 2, y: centerY)

                Capsule()
                    .fill(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 4, height: max(2, abs(centerY - thumbY)))
                    .position(x: geo.size.width / 2, y: (centerY + thumbY) / 2)

                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Circle()
                            .strokeBorder(isActive ? Color.accentColor : Color.secondary, lineWidth: 2)
                    )
                    .frame(width: 11, height: 11)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = 1.0 - Double(min(max(gesture.location.y / height, 0), 1))
                        let next = range.lowerBound + fraction * span
                        value = (next * 2.0).rounded() / 2.0
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
        }
    }
}

