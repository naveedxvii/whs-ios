import Foundation
import UIKit

extension ShopStore {
    var deviceName: String {
        "WaniShop - \(UIDevice.current.name)"
    }

    func startSharing() throws {
        let code = String(format: "%04d", Int.random(in: 0...9999))
        syncState.code = code
        save()
        do {
            try server.start(deviceName: deviceName)
            sharingCode = code
        } catch {
            syncState.code = ""
            throw error
        }
    }

    func stopSharing() {
        server.stop()
        syncState.code = ""
        sharingCode = ""
    }

    /// Replaces stock and sales with the incoming data. Settings stay as they are on this phone.
    func applySync(_ incoming: Backup) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        keepSnapshot("prereceive")
        var items = incoming.items
        for key in items.keys {
            items[key]?.barcode = key
        }
        backup.items = items
        backup.sales = incoming.sales
        if incoming.hasPayments {
            backup.payments = incoming.payments
        }
        cart = [:]
        let maxNo = incoming.sales.map { $0.no }.max() ?? 0
        let current = Int(setting("next_no")) ?? 1
        backup.settings["next_no"] = String(max(current, maxNo + 1))
        save()
        SyncMerge.forget()
    }
}
