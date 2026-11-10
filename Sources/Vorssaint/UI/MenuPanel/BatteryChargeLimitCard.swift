// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct BatteryChargeLimitStrings {
    let title: String
    let toggle: String
    let limitFormat: String
    let caption: String
    let requiresHelper: String
    let allowControl: String
    let unsupported: String
    let failed: String
    let currentFormat: String

    static func forLanguage(_ language: AppLanguage) -> BatteryChargeLimitStrings {
        switch language {
        case .ptBR:
            return .init(title: "Limite de carga da bateria",
                         toggle: "Limitar carga",
                         limitFormat: "Parar de carregar em %d%%",
                         caption: "Mantém a bateria abaixo do limite para reduzir o desgaste.",
                         requiresHelper: "Requer a mesma autorização do Controle da ventoinha.",
                         allowControl: "Permitir controle",
                         unsupported: "Este Mac não expõe o limite de carga (BCLM).",
                         failed: "O SMC recusou o limite. Tente outro valor.",
                         currentFormat: "SMC atual: %d%%")
        default:
            return .init(title: "Battery Charge Limit",
                         toggle: "Limit charging",
                         limitFormat: "Stop charging at %d%%",
                         caption: "Keeps the battery below the limit to reduce wear. Re-applied at launch and after wake.",
                         requiresHelper: "Uses the same authorization as Fan Control.",
                         allowControl: "Allow control",
                         unsupported: "This Mac does not expose a charge limit (BCLM).",
                         failed: "The SMC rejected the limit. Try another value.",
                         currentFormat: "SMC now: %d%%")
        }
    }
}

/// Intel battery charge limit card, shown inside the Fan Control section
/// because it shares the same privileged helper and authorization.
struct BatteryChargeLimitCard: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = BatteryChargeLimitService.shared
    @ObservedObject private var fanService = FanControlService.shared
    @AppStorage(DefaultsKey.batteryChargeLimitEnabled) private var enabled = false
    @AppStorage(DefaultsKey.batteryChargeLimit) private var limit =
        BatteryChargeLimitPolicy.defaultLimit

    private var strings: BatteryChargeLimitStrings { .forLanguage(l10n.language) }

    var body: some View {
        Group {
            if service.status?.supported == false {
                EmptyView()
            } else {
                content.panelCard()
            }
        }
        .onAppear { service.refresh() }
        .onChange(of: fanService.accessState) { _, state in
            if state == .enabled {
                service.refresh()
                if enabled { service.applyDesiredLimit() }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "battery.75percent")
                Text(strings.title).font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if let current = service.status?.limit {
                    Text(String(format: strings.currentFormat, current))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if fanService.accessState != .enabled {
                Text(strings.requiresHelper)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button(strings.allowControl, action: fanService.authorize)
                    .controlSize(.small)
                    .disabled(fanService.isWorking)
            } else {
                Toggle(strings.toggle, isOn: Binding(
                    get: { enabled },
                    set: { service.setEnabled($0) }
                ))
                .font(.system(size: 10.5, weight: .medium))
                .toggleStyle(.switch)
                .disabled(service.isWorking)

                if enabled {
                    Text(String(format: strings.limitFormat, limit))
                        .font(.system(size: 10.5).monospacedDigit())
                    Slider(value: Binding(
                        get: { Double(limit) },
                        set: { limit = Int($0) }
                    ),
                    in: Double(BatteryChargeLimitPolicy.minimumLimit)...Double(BatteryChargeLimitPolicy.maximumLimit),
                    step: Double(BatteryChargeLimitPolicy.step)) { editing in
                        if !editing { service.setLimit(limit) }
                    }
                    .disabled(service.isWorking)
                }

                if service.lastWriteFailed {
                    Text(strings.failed)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                } else if service.helperUnavailable {
                    Text(FeatureStrings.fanControl(l10n.language).helperUnavailable)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(strings.caption)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

