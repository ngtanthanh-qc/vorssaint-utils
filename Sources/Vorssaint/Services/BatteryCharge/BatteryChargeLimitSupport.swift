// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reply shared by the app and the privileged helper for battery charge limit.
struct BatteryChargeLimitStatus: Codable, Equatable, Sendable {
    /// Whether this Mac exposes the Intel `BCLM` SMC key.
    let supported: Bool
    /// The limit currently stored in the SMC, if it could be read.
    let limit: Int?
    /// Whether the last write request was accepted and read back.
    let succeeded: Bool

    static let unsupported = BatteryChargeLimitStatus(supported: false, limit: nil, succeeded: false)
}

enum BatteryChargeLimitPolicy {
    /// Intel firmware accepts 20...100, but very low limits are of little use
    /// and below 50 some models ignore the value. Match AlDente/bclm defaults.
    static let minimumLimit = 50
    static let maximumLimit = 100
    static let step = 5
    static let defaultLimit = 80

    static func validLimit(_ limit: Int) -> Bool {
        (minimumLimit...maximumLimit).contains(limit) && limit.isMultiple(of: step)
    }
}

enum BatteryChargeLimitIPC {
    static func encode(_ status: BatteryChargeLimitStatus) -> Data {
        (try? JSONEncoder().encode(status))
            ?? Data(#"{"supported":false,"succeeded":false}"#.utf8)
    }

    static func decode(_ data: Data) -> BatteryChargeLimitStatus? {
        try? JSONDecoder().decode(BatteryChargeLimitStatus.self, from: data)
    }
}

/// Intel-only SMC access for the battery charge limit. Writes only a
/// validated percentage to `BCLM` (and the matching `BFCL` LED threshold when
/// present). There is no arbitrary key entry point. Requires root.
final class BatteryChargeLimitHardware {
    private let client: SMCClient
    private let limitKey: SMCClient.Key?
    private let ledKey: SMCClient.Key?

    init?() {
        guard let client = SMCClient() else { return nil }
        self.client = client
        if let key = client.key(named: "BCLM"), key.dataSize == 1,
           client.readBytes(key)?.count == 1 {
            limitKey = key
        } else {
            limitKey = nil
        }
        if let key = client.key(named: "BFCL"), key.dataSize == 1 {
            ledKey = key
        } else {
            ledKey = nil
        }
    }

    var isSupported: Bool { limitKey != nil }

    static let hasChargeLimitKey: Bool = {
        BatteryChargeLimitHardware()?.isSupported == true
    }()

    func currentLimit() -> Int? {
        guard let limitKey, let bytes = client.readBytes(limitKey), bytes.count == 1 else {
            return nil
        }
        return Int(bytes[0])
    }

    func status(succeeded: Bool) -> BatteryChargeLimitStatus {
        guard isSupported else { return .unsupported }
        return BatteryChargeLimitStatus(supported: true, limit: currentLimit(),
                                        succeeded: succeeded)
    }

    /// Writes the limit and verifies it by reading it back.
    func setLimit(_ limit: Int) -> Bool {
        guard let limitKey, BatteryChargeLimitPolicy.validLimit(limit) else { return false }
        var written = false
        for attempt in 0..<5 {
            if (try? client.writeBytes([UInt8(limit)], to: limitKey)) != nil,
               currentLimit() == limit {
                written = true
                break
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard written else { return false }
        // MagSafe LED turns green at BFCL. Keep it just under the limit so
        // the LED reports "charged" once charging stops. Best effort only.
        if let ledKey {
            let led = limit >= BatteryChargeLimitPolicy.maximumLimit ? 100 : max(0, limit - 5)
            _ = try? client.writeBytes([UInt8(led)], to: ledKey)
        }
        return true
    }
}

