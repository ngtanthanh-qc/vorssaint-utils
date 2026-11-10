// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Foundation
import ServiceManagement

/// App side of the Intel battery charge limit. The SMC write runs in the
/// already-authorized Fan Control helper (root). The chosen limit lives in
/// UserDefaults and is re-applied at launch and after wake, because an SMC
/// reset or some firmware paths drop `BCLM` back to 100.
final class BatteryChargeLimitService: ObservableObject {
    static let shared = BatteryChargeLimitService()

    @Published private(set) var status: BatteryChargeLimitStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var lastWriteFailed = false
    @Published private(set) var helperUnavailable = false

    private let probeQueue = DispatchQueue(label: "com.vorssaint.battery-limit.probe",
                                           qos: .utility)
    private var probeHardware: BatteryChargeLimitHardware?
    private var connection: NSXPCConnection?
    private var observingWake = false
    private var requestGeneration = 0

    private static var helperEnabled: Bool {
        SMAppService.daemon(plistName: FanControlIdentifiers.plistName).status == .enabled
    }

    private init() {
        refreshLocalProbe()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        connection?.invalidate()
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.batteryChargeLimitEnabled)
    }

    var storedLimit: Int {
        let value = UserDefaults.standard.integer(forKey: DefaultsKey.batteryChargeLimit)
        return BatteryChargeLimitPolicy.validLimit(value) ? value : BatteryChargeLimitPolicy.defaultLimit
    }

    /// The limit the SMC should hold right now given the user's choice.
    var desiredLimit: Int {
        isEnabled ? storedLimit : BatteryChargeLimitPolicy.maximumLimit
    }

    /// Called once at launch: observe wake and re-apply a saved limit.
    func start() {
        if !observingWake {
            observingWake = true
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(didWake),
                name: NSWorkspace.didWakeNotification, object: nil)
        }
        if isEnabled { applyDesiredLimit() }
    }

    func refresh() {
        guard Self.helperEnabled else {
            refreshLocalProbe()
            return
        }
        send({ proxy, reply in proxy.batteryChargeLimit(withReply: reply) }) { [weak self] status in
            guard let self else { return }
            if let status {
                self.helperUnavailable = false
                self.status = status
            } else {
                self.helperUnavailable = true
                self.refreshLocalProbe()
            }
        }
    }

    private func refreshLocalProbe() {
        probeQueue.async { [weak self] in
            guard let self else { return }
            if self.probeHardware == nil {
                self.probeHardware = BatteryChargeLimitHardware()
            }
            let localStatus = self.probeHardware?.status(succeeded: true) ?? .unsupported
            DispatchQueue.main.async {
                self.status = localStatus
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.batteryChargeLimitEnabled)
        applyDesiredLimit()
    }

    func setLimit(_ limit: Int) {
        guard BatteryChargeLimitPolicy.validLimit(limit) else { return }
        UserDefaults.standard.set(limit, forKey: DefaultsKey.batteryChargeLimit)
        if isEnabled { applyDesiredLimit() }
    }

    func applyDesiredLimit() {
        guard Self.helperEnabled else { return }
        let limit = desiredLimit
        requestGeneration += 1
        let generation = requestGeneration
        isWorking = true
        lastWriteFailed = false
        helperUnavailable = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.requestGeneration == generation, self.isWorking else { return }
            self.isWorking = false
            self.helperUnavailable = true
            self.connection?.invalidate()
            self.connection = nil
            self.refreshLocalProbe()
        }
        send({ proxy, reply in proxy.setBatteryChargeLimit(limit, withReply: reply) }) { [weak self] status in
            guard let self, self.requestGeneration == generation else { return }
            self.isWorking = false
            if let status {
                self.helperUnavailable = false
                self.status = status
                self.lastWriteFailed = status.supported && !status.succeeded
            } else {
                self.helperUnavailable = true
                self.refreshLocalProbe()
            }
        }
    }

    /// Synchronously puts charging back to 100% before the helper is removed.
    static func resetForRemoval(using proxy: FanControlXPCProtocol) {
        let semaphore = DispatchSemaphore(value: 0)
        proxy.setBatteryChargeLimit(BatteryChargeLimitPolicy.maximumLimit) { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    @objc private func didWake() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.applyDesiredLimit()
        }
    }

    // MARK: - XPC

    private func send(_ operation: @escaping (FanControlXPCProtocol, @escaping (Data) -> Void) -> Void,
                      completion: @escaping (BatteryChargeLimitStatus?) -> Void) {
        var finished = false
        let finish: (BatteryChargeLimitStatus?) -> Void = { status in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(status)
            }
        }
        guard let proxy = proxy(errorHandler: { finish(nil) }) else {
            finish(nil)
            return
        }
        operation(proxy) { data in finish(BatteryChargeLimitIPC.decode(data)) }
    }

    private func proxy(errorHandler: @escaping () -> Void) -> FanControlXPCProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: FanControlIdentifiers.helperID,
                                             options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCProtocol.self)
            connection.setCodeSigningRequirement(FanControlIdentifiers.helperCodeRequirement)
            let reset: () -> Void = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    guard let connection, self?.connection === connection else { return }
                    connection.invalidate()
                    self?.connection = nil
                }
            }
            connection.interruptionHandler = reset
            connection.invalidationHandler = reset
            connection.activate()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.connection?.invalidate()
                self?.connection = nil
            }
            errorHandler()
        } as? FanControlXPCProtocol
    }
}

