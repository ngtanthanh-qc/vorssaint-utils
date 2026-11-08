// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreAudio
import Darwin
import Foundation
import os.lock

/// FxSound-inspired 9-band graphic equalizer and 5-stage psychoacoustic DSP
/// processor (Clarity, Ambience, Surround Sound, Dynamic Boost, Bass Boost).
///
/// Designed for zero allocations on the CoreAudio realtime IO thread: the UI
/// compiles biquad filter coefficients and effect parameters into an immutable
/// `FxSoundCompiledParameters` snapshot, and each audio stream's `FxSoundDSPState`
/// copies that value type only when its generation counter advances.
enum FxSoundBand: Int, CaseIterable, Identifiable {
    case hz86 = 0
    case hz115 = 1
    case hz250 = 2
    case hz450 = 3
    case hz630 = 4
    case khz1_25 = 5
    case khz2_7 = 6
    case khz5_3 = 7
    case khz13 = 8

    var id: Int { rawValue }

    /// Center frequencies modeled after FxSound's 9-band graphic EQ.
    var frequency: Double {
        switch self {
        case .hz86: return 86
        case .hz115: return 115
        case .hz250: return 250
        case .hz450: return 450
        case .hz630: return 630
        case .khz1_25: return 1250
        case .khz2_7: return 2700
        case .khz5_3: return 5300
        case .khz13: return 13000
        }
    }

    var shortLabel: String {
        switch self {
        case .hz86: return "86"
        case .hz115: return "115"
        case .hz250: return "250"
        case .hz450: return "450"
        case .hz630: return "630"
        case .khz1_25: return "1.3k"
        case .khz2_7: return "2.7k"
        case .khz5_3: return "5.3k"
        case .khz13: return "13k"
        }
    }

    var qFactor: Double {
        switch self {
        case .hz86, .hz115: return 1.15
        case .hz250, .hz450, .hz630, .khz1_25, .khz2_7, .khz5_3: return 1.41
        case .khz13: return 1.10
        }
    }
}

/// The five signature FxSound enhancement controls (0...10).
enum FxSoundEffect: String, CaseIterable, Identifiable {
    case clarity
    case ambience
    case surround
    case dynamicBoost
    case bassBoost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clarity: return "Clarity"
        case .ambience: return "Ambience"
        case .surround: return "Surround Sound"
        case .dynamicBoost: return "Dynamic Boost"
        case .bassBoost: return "Bass Boost"
        }
    }

    var iconName: String {
        switch self {
        case .clarity: return "sparkles"
        case .ambience: return "waveform.badge.magnifyingglass"
        case .surround: return "hifispeaker.2.fill"
        case .dynamicBoost: return "bolt.horizontal.fill"
        case .bassBoost: return "speaker.wave.3.fill"
        }
    }
}

/// Built-in presets matching FxSound's classic profiles.
enum FxSoundPreset: String, CaseIterable, Identifiable {
    case general
    case music
    case movies
    case gaming
    case voice
    case bassBoost
    case streamingVideo
    case flat
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .music: return "Music"
        case .movies: return "Movies"
        case .gaming: return "Gaming"
        case .voice: return "Voice / Podcast"
        case .bassBoost: return "Bass Boost"
        case .streamingVideo: return "Streaming Video"
        case .flat: return "Flat"
        case .custom: return "Custom"
        }
    }

    /// 9-band gains in dB (-12...+12) for this preset.
    var bandGains: [Double] {
        switch self {
        case .general:
            return [2.0, 2.5, 1.0, 0.0, 0.0, 1.0, 2.0, 2.5, 3.0]
        case .music:
            return [3.5, 4.0, 1.5, -0.5, 0.0, 1.5, 3.0, 4.0, 4.5]
        case .movies:
            return [4.5, 4.0, 1.0, -1.0, 1.5, 2.5, 3.0, 2.5, 3.5]
        case .gaming:
            return [3.0, 2.5, 0.0, -1.0, 1.0, 3.5, 4.5, 4.0, 3.0]
        case .voice:
            return [-3.0, -1.5, 1.0, 2.5, 3.5, 4.0, 3.5, 2.0, 1.0]
        case .bassBoost:
            return [6.5, 6.0, 3.0, 0.5, 0.0, 0.5, 1.5, 2.0, 2.5]
        case .streamingVideo:
            return [2.0, 2.0, 1.0, 1.0, 2.0, 3.0, 3.0, 2.5, 2.0]
        case .flat, .custom:
            return Array(repeating: 0.0, count: FxSoundBand.allCases.count)
        }
    }

    /// The 5 FxSound effect levels (0...10) for this preset.
    var effectLevels: [FxSoundEffect: Double] {
        switch self {
        case .general:
            return [.clarity: 5, .ambience: 2, .surround: 3, .dynamicBoost: 4, .bassBoost: 4]
        case .music:
            return [.clarity: 6, .ambience: 2, .surround: 4, .dynamicBoost: 5, .bassBoost: 6]
        case .movies:
            return [.clarity: 6, .ambience: 4, .surround: 7, .dynamicBoost: 6, .bassBoost: 6]
        case .gaming:
            return [.clarity: 7, .ambience: 2, .surround: 8, .dynamicBoost: 6, .bassBoost: 5]
        case .voice:
            return [.clarity: 8, .ambience: 0, .surround: 1, .dynamicBoost: 6, .bassBoost: 1]
        case .bassBoost:
            return [.clarity: 5, .ambience: 1, .surround: 3, .dynamicBoost: 6, .bassBoost: 9]
        case .streamingVideo:
            return [.clarity: 6, .ambience: 2, .surround: 3, .dynamicBoost: 7, .bassBoost: 4]
        case .flat, .custom:
            return [.clarity: 0, .ambience: 0, .surround: 0, .dynamicBoost: 0, .bassBoost: 0]
        }
    }
}

/// Normalized biquad filter coefficients (Direct Form II Transposed).
struct FxSoundBiquadCoefficients: Equatable {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    var isIdentity: Bool {
        abs(b0 - 1) < 1e-5 && abs(b1) < 1e-5 && abs(b2) < 1e-5 && abs(a1) < 1e-5 && abs(a2) < 1e-5
    }

    static let identity = FxSoundBiquadCoefficients()

    /// Audio EQ Cookbook peaking filter at `frequency` Hz with `gainDB` (-15...+15 dB).
    static func peaking(frequency: Double, sampleRate: Double, q: Double, gainDB: Double) -> FxSoundBiquadCoefficients {
        guard abs(gainDB) >= 0.05, sampleRate > 8000, frequency > 10, frequency < sampleRate * 0.47 else {
            return .identity
        }
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * max(q, 0.1))

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a
        let invA0 = 1.0 / a0
        return FxSoundBiquadCoefficients(
            b0: Float(b0 * invA0),
            b1: Float(b1 * invA0),
            b2: Float(b2 * invA0),
            a1: Float(a1 * invA0),
            a2: Float(a2 * invA0)
        )
    }

    /// Audio EQ Cookbook low-shelf filter (used by FxSound Bass Boost).
    static func lowShelf(frequency: Double, sampleRate: Double, q: Double, gainDB: Double) -> FxSoundBiquadCoefficients {
        guard abs(gainDB) >= 0.05, sampleRate > 8000, frequency > 10, frequency < sampleRate * 0.47 else {
            return .identity
        }
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * max(q, 0.1))
        let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha

        let b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)
        let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
        let b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)
        let a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha
        let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
        let a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha
        let invA0 = 1.0 / a0
        return FxSoundBiquadCoefficients(
            b0: Float(b0 * invA0),
            b1: Float(b1 * invA0),
            b2: Float(b2 * invA0),
            a1: Float(a1 * invA0),
            a2: Float(a2 * invA0)
        )
    }

    /// Audio EQ Cookbook high-shelf filter (used by FxSound Clarity).
    static func highShelf(frequency: Double, sampleRate: Double, q: Double, gainDB: Double) -> FxSoundBiquadCoefficients {
        guard abs(gainDB) >= 0.05, sampleRate > 8000, frequency > 10, frequency < sampleRate * 0.47 else {
            return .identity
        }
        let a = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * max(q, 0.1))
        let twoSqrtAAlpha = 2.0 * sqrt(a) * alpha

        let b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)
        let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)
        let b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)
        let a0 = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha
        let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0)
        let a2 = (a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha
        let invA0 = 1.0 / a0
        return FxSoundBiquadCoefficients(
            b0: Float(b0 * invA0),
            b1: Float(b1 * invA0),
            b2: Float(b2 * invA0),
            a1: Float(a1 * invA0),
            a2: Float(a2 * invA0)
        )
    }
}

/// Fixed-size value type containing all compiled biquad stages and effect
/// parameters for the realtime audio thread.
struct FxSoundCompiledParameters {
    static let stageCount = 12 // 9 EQ bands + Bass Boost shelf + Clarity presence + Clarity air shelf

    var generation: UInt64 = 0
    var isEnabled: Bool = false
    /// Fixed 12 stages stored inline as a tuple to avoid heap array reads on the audio thread.
    var stages: (
        FxSoundBiquadCoefficients, FxSoundBiquadCoefficients, FxSoundBiquadCoefficients,
        FxSoundBiquadCoefficients, FxSoundBiquadCoefficients, FxSoundBiquadCoefficients,
        FxSoundBiquadCoefficients, FxSoundBiquadCoefficients, FxSoundBiquadCoefficients,
        FxSoundBiquadCoefficients, FxSoundBiquadCoefficients, FxSoundBiquadCoefficients
    ) = (
        .identity, .identity, .identity, .identity, .identity, .identity,
        .identity, .identity, .identity, .identity, .identity, .identity
    )
    var activeStageCount: Int = 0
    var preampGain: Float = 1.0
    var clarityExciterAmount: Float = 0.0
    var bassHarmonicAmount: Float = 0.0
    var surroundSideGain: Float = 1.0
    var ambienceMix: Float = 0.0
    var dynamicBoostAmount: Float = 0.0
    var dynamicMakeupGain: Float = 1.0

    static func compile(generation: UInt64,
                        isEnabled: Bool,
                        bandGains: [Double],
                        effects: [FxSoundEffect: Double],
                        sampleRate: Double = 48000) -> FxSoundCompiledParameters {
        var params = FxSoundCompiledParameters()
        params.generation = generation
        guard isEnabled else { return params }

        let clarity = min(max(effects[.clarity] ?? 0, 0), 10)
        let ambience = min(max(effects[.ambience] ?? 0, 0), 10)
        let surround = min(max(effects[.surround] ?? 0, 0), 10)
        let dynamicBoost = min(max(effects[.dynamicBoost] ?? 0, 0), 10)
        let bassBoost = min(max(effects[.bassBoost] ?? 0, 0), 10)

        var list: [FxSoundBiquadCoefficients] = []
        list.reserveCapacity(Self.stageCount)

        var maxPositiveGainDB = 0.0
        for band in FxSoundBand.allCases {
            let gain = band.rawValue < bandGains.count
                ? min(max(bandGains[band.rawValue], -12.0), 12.0)
                : 0.0
            if gain > maxPositiveGainDB { maxPositiveGainDB = gain }
            let coeff = FxSoundBiquadCoefficients.peaking(
                frequency: band.frequency,
                sampleRate: sampleRate,
                q: band.qFactor,
                gainDB: gain
            )
            if !coeff.isIdentity {
                list.append(coeff)
            }
        }

        // FxSound Bass Boost: resonant low-shelf around 68 Hz (up to +8.5 dB)
        if bassBoost > 0.05 {
            let bassDB = bassBoost * 0.85
            maxPositiveGainDB += bassDB * 0.55
            let shelf = FxSoundBiquadCoefficients.lowShelf(
                frequency: 68,
                sampleRate: sampleRate,
                q: 0.82,
                gainDB: bassDB
            )
            if !shelf.isIdentity {
                list.append(shelf)
            }
        }

        // FxSound Clarity: upper-mid definition (3.6 kHz) + high-shelf air (9.5 kHz)
        if clarity > 0.05 {
            let presenceDB = clarity * 0.42
            let airDB = clarity * 0.65
            maxPositiveGainDB = max(maxPositiveGainDB, airDB * 0.6)
            let presence = FxSoundBiquadCoefficients.peaking(
                frequency: 3600,
                sampleRate: sampleRate,
                q: 1.1,
                gainDB: presenceDB
            )
            if !presence.isIdentity { list.append(presence) }
            let air = FxSoundBiquadCoefficients.highShelf(
                frequency: 9500,
                sampleRate: sampleRate,
                q: 0.75,
                gainDB: airDB
            )
            if !air.isIdentity { list.append(air) }
        }

        let hasAnyEffect = !list.isEmpty
            || clarity > 0.05
            || ambience > 0.05
            || surround > 0.05
            || dynamicBoost > 0.05
            || bassBoost > 0.05

        guard hasAnyEffect else { return params }

        params.isEnabled = true
        params.activeStageCount = min(list.count, Self.stageCount)
        withUnsafeMutablePointer(to: &params.stages) { tuplePtr in
            let buffer = UnsafeMutableRawPointer(tuplePtr)
                .assumingMemoryBound(to: FxSoundBiquadCoefficients.self)
            for idx in 0..<params.activeStageCount {
                buffer[idx] = list[idx]
            }
        }

        // Headroom management: gently attenuate preamp when heavy EQ boosts are
        // dialed in without Dynamic Boost, while Dynamic Boost restores and
        // lifts overall loudness into the lookahead peak limiter.
        let headroomTrimDB = -min(maxPositiveGainDB * 0.25, 4.5)
        params.preampGain = Float(pow(10.0, headroomTrimDB / 20.0))

        params.clarityExciterAmount = Float(clarity / 10.0) * 0.14
        params.bassHarmonicAmount = Float(bassBoost / 10.0) * 0.12
        // Surround widens the Side (L-R) channel up to 1.85x while keeping bass anchored.
        params.surroundSideGain = 1.0 + Float(surround / 10.0) * 0.85
        // Ambience blends a short Haas cross-reflection (up to 22%).
        params.ambienceMix = Float(ambience / 10.0) * 0.22
        // Dynamic Boost: upward compression + makeup gain up to +6.5 dB.
        params.dynamicBoostAmount = Float(dynamicBoost / 10.0)
        let makeupDB = (dynamicBoost / 10.0) * 6.5
        params.dynamicMakeupGain = Float(pow(10.0, makeupDB / 20.0))

        return params
    }
}

/// Lock-free / unfair-lock atomic box holding the latest compiled DSP snapshot
/// for the realtime audio thread.
final class FxSoundParameterBox {
    static let shared = FxSoundParameterBox()

    private var lock = os_unfair_lock_s()
    private var current = FxSoundCompiledParameters()

    var isActive: Bool {
        os_unfair_lock_lock(&lock)
        let active = current.isEnabled
        os_unfair_lock_unlock(&lock)
        return active
    }

    func load() -> FxSoundCompiledParameters {
        os_unfair_lock_lock(&lock)
        let snapshot = current
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func store(_ parameters: FxSoundCompiledParameters) {
        os_unfair_lock_lock(&lock)
        current = parameters
        os_unfair_lock_unlock(&lock)
    }
}

/// Per-stream DSP state owned by `BoostLookaheadBufferListLimiter`.
/// Preallocates all filter delay lines and reflection buffers at init so
/// `process` never allocates on the CoreAudio realtime thread.
final class FxSoundDSPState {
    static let ambienceDelayFrames = 512 // ~10.6 ms at 48 kHz

    private let channelCapacity: Int
    /// Direct Form II Transposed state: 2 floats (`z1`, `z2`) per stage per channel.
    private var biquadState: ContiguousArray<Float>
    /// Circular Haas reflection buffer for stereo Ambience (L & R).
    private var ambienceRingL: ContiguousArray<Float>
    private var ambienceRingR: ContiguousArray<Float>
    private var ambiencePos: Int = 0
    private var ambienceLowpassL: Float = 0
    private var ambienceLowpassR: Float = 0
    /// 1-pole low-pass state on the Side channel so Surround keeps bass centered.
    private var sideBassState: Float = 0
    /// Smooth envelope follower for Dynamic Boost upward compression.
    private var dynamicEnvelope: Float = 0.1
    private var appliedGeneration: UInt64 = 0
    private var cachedParams = FxSoundCompiledParameters()

    init(channelCapacity: Int) {
        let cap = max(2, channelCapacity)
        self.channelCapacity = cap
        self.biquadState = ContiguousArray(
            repeating: 0,
            count: FxSoundCompiledParameters.stageCount * cap * 2
        )
        self.ambienceRingL = ContiguousArray(repeating: 0, count: Self.ambienceDelayFrames)
        self.ambienceRingR = ContiguousArray(repeating: 0, count: Self.ambienceDelayFrames)
    }

    func reset() {
        biquadState.withUnsafeMutableBufferPointer {
            $0.baseAddress?.update(repeating: 0, count: $0.count)
        }
        ambienceRingL.withUnsafeMutableBufferPointer {
            $0.baseAddress?.update(repeating: 0, count: $0.count)
        }
        ambienceRingR.withUnsafeMutableBufferPointer {
            $0.baseAddress?.update(repeating: 0, count: $0.count)
        }
        ambiencePos = 0
        ambienceLowpassL = 0
        ambienceLowpassR = 0
        sideBassState = 0
        dynamicEnvelope = 0.1
    }

    /// Processes `frames` frames across `buffers` in-place on the realtime thread.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let latest = FxSoundParameterBox.shared.load()
        guard latest.isEnabled, frames > 0 else {
            if cachedParams.isEnabled {
                cachedParams = latest
                reset()
            }
            return
        }
        if latest.generation != appliedGeneration {
            appliedGeneration = latest.generation
            cachedParams = latest
        }

        let stageCount = cachedParams.activeStageCount
        let preamp = cachedParams.preampGain
        let dynAmount = cachedParams.dynamicBoostAmount
        let dynMakeup = cachedParams.dynamicMakeupGain
        let clarityExciter = cachedParams.clarityExciterAmount
        let bassHarmonic = cachedParams.bassHarmonicAmount
        let surroundSideGain = cachedParams.surroundSideGain
        let ambienceMix = cachedParams.ambienceMix

        withUnsafePointer(to: &cachedParams.stages) { tuplePtr in
            let stages = UnsafeRawPointer(tuplePtr)
                .assumingMemoryBound(to: FxSoundBiquadCoefficients.self)

            biquadState.withUnsafeMutableBufferPointer { stateBuf in
                guard let zBase = stateBuf.baseAddress else { return }

                // 1. Per-channel cascaded Biquad EQ + Preamp + Harmonic Exciters
                var globalChannel = 0
                for buffer in buffers {
                    let chCount = Int(buffer.mNumberChannels)
                    guard chCount > 0,
                          let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for ch in 0..<chCount where (globalChannel + ch) < channelCapacity {
                        let chIdx = globalChannel + ch
                        let stateOffset = chIdx * FxSoundCompiledParameters.stageCount * 2
                        for frame in 0..<frames {
                            let idx = frame * chCount + ch
                            var x = samples[idx] * preamp
                            for stage in 0..<stageCount {
                                let c = stages[stage]
                                let zIdx = stateOffset + stage * 2
                                let z1 = zBase[zIdx]
                                let z2 = zBase[zIdx + 1]
                                let y = c.b0 * x + z1
                                zBase[zIdx] = c.b1 * x - c.a1 * y + z2
                                zBase[zIdx + 1] = c.b2 * x - c.a2 * y
                                x = y
                            }
                            if clarityExciter > 0 || bassHarmonic > 0 {
                                // Subtle soft-saturation harmonic enrichment
                                let drive = 1.0 + clarityExciter + bassHarmonic
                                let driven = x * drive
                                x = driven / (1.0 + 0.28 * abs(driven))
                            }
                            samples[idx] = x
                        }
                    }
                    globalChannel += chCount
                }
            }
        }

        // 2. Stereo Spatial Stage (Surround Sound M/S Widening + Ambience Haas Cross-Reflection)
        if surroundSideGain > 1.001 || ambienceMix > 0.001 {
            if buffers.count == 1, Int(buffers[0].mNumberChannels) >= 2,
               let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let stride = Int(buffers[0].mNumberChannels)
                processStereoSpatial(
                    left: samples,
                    right: samples + 1,
                    stride: stride,
                    frames: frames,
                    surroundSideGain: surroundSideGain,
                    ambienceMix: ambienceMix
                )
            } else if buffers.count >= 2,
                      buffers[0].mNumberChannels == 1,
                      buffers[1].mNumberChannels == 1,
                      let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                processStereoSpatial(
                    left: left,
                    right: right,
                    stride: 1,
                    frames: frames,
                    surroundSideGain: surroundSideGain,
                    ambienceMix: ambienceMix
                )
            }
        }

        // 3. FxSound Dynamic Boost (Upward dynamic compression + makeup gain)
        if dynAmount > 0.01 {
            var env = dynamicEnvelope
            for frame in 0..<frames {
                var peak: Float = 0
                for buffer in buffers {
                    let chCount = Int(buffer.mNumberChannels)
                    guard chCount > 0,
                          let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let base = frame * chCount
                    for ch in 0..<chCount {
                        peak = max(peak, abs(samples[base + ch]))
                    }
                }
                // Fast attack (1.5 ms), smooth release (90 ms)
                let coeff: Float = peak > env ? 0.015 : 0.00025
                env += (peak - env) * coeff
                let clampedEnv = min(max(env, 0.02), 1.0)
                // Quiet passages receive more lift; loud peaks taper toward unity
                // before hitting the lookahead brickwall limiter.
                let dynamicLift = 1.0 + (dynMakeup - 1.0) * powf(1.0 - clampedEnv * 0.65, 1.3)
                for buffer in buffers {
                    let chCount = Int(buffer.mNumberChannels)
                    guard chCount > 0,
                          let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let base = frame * chCount
                    for ch in 0..<chCount {
                        samples[base + ch] *= dynamicLift
                    }
                }
            }
            dynamicEnvelope = env
        }
    }

    private func processStereoSpatial(left: UnsafeMutablePointer<Float>,
                                      right: UnsafeMutablePointer<Float>,
                                      stride: Int,
                                      frames: Int,
                                      surroundSideGain: Float,
                                      ambienceMix: Float) {
        var pos = ambiencePos
        var lpL = ambienceLowpassL
        var lpR = ambienceLowpassR
        var bassS = sideBassState
        let ringMask = Self.ambienceDelayFrames - 1

        ambienceRingL.withUnsafeMutableBufferPointer { ringL in
            ambienceRingR.withUnsafeMutableBufferPointer { ringR in
                guard let rL = ringL.baseAddress, let rR = ringR.baseAddress else { return }
                for frame in 0..<frames {
                    let idx = frame * stride
                    var l = left[idx]
                    var r = right[idx]

                    // Surround Sound: Mid/Side expansion above ~160 Hz so bass stays tight & centered
                    if surroundSideGain > 1.001 {
                        let mid = 0.5 * (l + r)
                        let side = 0.5 * (l - r)
                        bassS += 0.02 * (side - bassS)
                        let highSide = side - bassS
                        let widenedSide = bassS + highSide * surroundSideGain
                        l = mid + widenedSide
                        r = mid - widenedSide
                    }

                    // Ambience: Damped Haas cross-reflection between L and R
                    if ambienceMix > 0.001 {
                        let delayedL = rL[pos]
                        let delayedR = rR[pos]
                        lpL = 0.65 * lpL + 0.35 * l
                        lpR = 0.65 * lpR + 0.35 * r
                        rL[pos] = lpL - delayedR * 0.18
                        rR[pos] = lpR - delayedL * 0.18
                        l += delayedR * ambienceMix
                        r += delayedL * ambienceMix
                        pos = (pos + 1) & ringMask
                    }

                    left[idx] = l
                    right[idx] = r
                }
            }
        }
        ambiencePos = pos
        ambienceLowpassL = lpL
        ambienceLowpassR = lpR
        sideBassState = bassS
    }
}

