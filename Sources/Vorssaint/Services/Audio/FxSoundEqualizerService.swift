// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Observable controller for the FxSound-style system-wide 9-band graphic
/// equalizer, 5 psychoacoustic effects, and presets.
final class FxSoundEqualizerService: ObservableObject {
    static let shared = FxSoundEqualizerService()

    private static let enabledKey = "fxsoundEQEnabled"
    private static let presetKey = "fxsoundEQPreset"
    private static let bandGainsKey = "fxsoundEQBandGains"
    private static let effectsKey = "fxsoundEQEffects"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            pushCompiledParameters()
            AppVolumeMixer.shared.reconcileForEqualizerChange()
        }
    }

    @Published private(set) var preset: FxSoundPreset
    @Published private(set) var bandGains: [Double]
    @Published private(set) var effects: [FxSoundEffect: Double]

    private var generation: UInt64 = 1

    private init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Self.enabledKey)
        let savedPreset = defaults.string(forKey: Self.presetKey)
            .flatMap(FxSoundPreset.init(rawValue:)) ?? .general

        var loadedBands = savedPreset.bandGains
        if let rawBands = defaults.array(forKey: Self.bandGainsKey) as? [Double],
           rawBands.count == FxSoundBand.allCases.count {
            loadedBands = rawBands.map { min(max($0, -12.0), 12.0) }
        }

        var loadedEffects = savedPreset.effectLevels
        if let rawEffects = defaults.dictionary(forKey: Self.effectsKey) as? [String: Double] {
            for effect in FxSoundEffect.allCases {
                if let val = rawEffects[effect.rawValue], val.isFinite {
                    loadedEffects[effect] = min(max(val, 0.0), 10.0)
                }
            }
        }

        self.isEnabled = enabled
        self.preset = savedPreset
        self.bandGains = loadedBands
        self.effects = loadedEffects
        pushCompiledParameters()
    }

    func selectPreset(_ nextPreset: FxSoundPreset) {
        preset = nextPreset
        UserDefaults.standard.set(nextPreset.rawValue, forKey: Self.presetKey)
        if nextPreset != .custom {
            bandGains = nextPreset.bandGains
            effects = nextPreset.effectLevels
            persistValues()
        }
        let wasActive = FxSoundParameterBox.shared.isActive
        pushCompiledParameters()
        if FxSoundParameterBox.shared.isActive != wasActive {
            AppVolumeMixer.shared.reconcileForEqualizerChange()
        }
    }

    func setBandGain(_ gainDB: Double, for band: FxSoundBand) {
        let clamped = (min(max(gainDB, -12.0), 12.0) * 2.0).rounded() / 2.0
        guard band.rawValue < bandGains.count, abs(bandGains[band.rawValue] - clamped) > 0.01 else { return }
        bandGains[band.rawValue] = clamped
        if preset != .custom {
            preset = .custom
            UserDefaults.standard.set(FxSoundPreset.custom.rawValue, forKey: Self.presetKey)
        }
        persistValues()
        let wasActive = FxSoundParameterBox.shared.isActive
        pushCompiledParameters()
        if FxSoundParameterBox.shared.isActive != wasActive {
            AppVolumeMixer.shared.reconcileForEqualizerChange()
        }
    }

    func setEffectLevel(_ level: Double, for effect: FxSoundEffect) {
        let clamped = (min(max(level, 0.0), 10.0) * 2.0).rounded() / 2.0
        guard abs((effects[effect] ?? 0) - clamped) > 0.01 else { return }
        effects[effect] = clamped
        if preset != .custom {
            preset = .custom
            UserDefaults.standard.set(FxSoundPreset.custom.rawValue, forKey: Self.presetKey)
        }
        persistValues()
        let wasActive = FxSoundParameterBox.shared.isActive
        pushCompiledParameters()
        if FxSoundParameterBox.shared.isActive != wasActive {
            AppVolumeMixer.shared.reconcileForEqualizerChange()
        }
    }

    func resetToPresetDefault() {
        let target = preset == .custom ? .general : preset
        selectPreset(target)
    }

    private func persistValues() {
        UserDefaults.standard.set(bandGains, forKey: Self.bandGainsKey)
        var rawEffects: [String: Double] = [:]
        for (key, value) in effects {
            rawEffects[key.rawValue] = value
        }
        UserDefaults.standard.set(rawEffects, forKey: Self.effectsKey)
    }

    private func pushCompiledParameters() {
        generation &+= 1
        let compiled = FxSoundCompiledParameters.compile(
            generation: generation,
            isEnabled: isEnabled,
            bandGains: bandGains,
            effects: effects
        )
        FxSoundParameterBox.shared.store(compiled)
    }
}

