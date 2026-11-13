import Foundation

struct SyncOutcome {
    var uploaded = false
    var changedHere = false
    var renumbered = 0
    var conflicts = 0

    /// A short note for the screen, or nil when there is nothing to tell.
    var note: String? {
        var parts: [String] = []
        if renumbered > 0 {
            parts.append("\(renumbered) bill(s) got a new number because both phones used the same one.")
        }
        if conflicts > 0 {
            parts.append("\(conflicts) item(s) differed on the first sync. Google Drive's copy was used.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Keeps this phone and Google Drive in step. After every change (and when the app comes to
/// the front) it merges the Drive copy with this phone's data and saves the result to both,
/// so changes made on either phone show up on the other.
@MainActor
final class AutoSync {
    static let shared = AutoSync()
    private var pendingTask: Task<Void, Never>?
    private var running = false
    private var rerun = false
    private let lastKey = "drive.lastModified"
    private let snapshotKey = "sync.lastSnapshot"

    /// Set after each sync when something needs the owner's attention.
    var lastNote: String?

    private var lastKnown: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: lastKey)) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastKey) }
    }

    /// Called after every change. Waits a few seconds so quick edits are saved together.
    func changed(_ store: ShopStore) {
        guard GoogleAuth.shared.isSignedIn else { return }
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await self.runAndRetry(store)
        }
    }

    private func runAndRetry(_ store: ShopStore) async {
        do {
            let outcome = try await syncNow(store)
            lastNote = outcome.note
        } catch {
            // Try again in a minute.
            pendingTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { return }
                await self.runAndRetry(store)
            }
        }
    }

    /// When the app comes to the front: merge if Drive has a newer copy (or on the first sync).
    func pullIfNewer(_ store: ShopStore) async {
        guard GoogleAuth.shared.isSignedIn, !running else { return }
        do {
            if let remote = try await DriveSync.remoteModified(),
               lastKnown.timeIntervalSince1970 > 0,
               remote <= lastKnown.addingTimeInterval(1) {
                return
            }
            let outcome = try await syncNow(store)
            lastNote = outcome.note
        } catch {
            // Try again the next time the app comes to the front.
        }
    }

    /// Merges Drive's copy with this phone's data and uploads the result when it differs.
    @discardableResult
    func syncNow(_ store: ShopStore) async throws -> SyncOutcome {
        if running {
            rerun = true
            return SyncOutcome()
        }
        running = true
        defer {
            running = false
            if rerun {
                rerun = false
                changed(store)
            }
        }

        var remoteData: Data?
        var remoteTime: Date?
        if let modified = try await DriveSync.remoteModified() {
            remoteData = try await DriveSync.download().0
            remoteTime = modified
        }

        // Everything from here to the upload runs without waiting, so no change on this phone
        // can slip in between reading the data and merging it.
        var remoteBackup: Backup?
        if let data = remoteData {
            guard let decoded = try? JSONDecoder().decode(Backup.self, from: data) else {
                throw GoogleError.badResponse
            }
            remoteBackup = decoded
        }
        let remoteState = remoteBackup.map { SyncMerge.state(from: $0) }
        var lineage = remoteBackup?.revs ?? []
        if let rev = remoteBackup?.rev { lineage.append(rev) }

        let base = SyncMerge.resolveBase(lineage: Set(lineage))
        let local = SyncMerge.state(from: store.backup)
        let (merged, report) = SyncMerge.merge(base: base, local: local, remote: remoteState)

        var outcome = SyncOutcome()
        outcome.renumbered = report.renumbered.count
        outcome.conflicts = report.conflicts.count

        if !SyncMerge.sameContent(merged, local) {
            keepSafetyCopy(store)
            apply(merged, to: store)
            outcome.changedHere = true
        }

        var upload: Data?
        if let remoteState, SyncMerge.sameContent(merged, remoteState) {
            SyncMerge.saveBase(merged, rev: remoteBackup?.rev)
        } else {
            upload = SyncMerge.exportForUpload(merged, remote0: remoteState, lineage: lineage)
        }

        if let upload {
            lastKnown = try await DriveSync.upload(upload)
            outcome.uploaded = true
        } else if let remoteTime {
            lastKnown = remoteTime
        }
        return outcome
    }

    /// The phone's data now equals the Drive copy that was just loaded by hand.
    func adoptAsBase(_ store: ShopStore, rev: String?) {
        SyncMerge.saveBase(SyncMerge.state(from: store.backup), rev: rev)
    }

    private func apply(_ merged: MergeState, to store: ShopStore) {
        store.isApplyingRemote = true
        defer { store.isApplyingRemote = false }
        store.backup.items = merged.items
        store.backup.sales = merged.sales
        store.backup.payments = merged.payments
        store.backup.hasPayments = true
        for (k, v) in merged.settings {
            store.backup.settings[k] = v
        }
        // Keep the bill being made, but drop lines for items that no longer exist.
        store.cart = store.cart.filter { merged.items[$0.key] != nil }
        store.save()
    }

    /// A copy of the data before a merge changes it, at most once every six hours.
    private func keepSafetyCopy(_ store: ShopStore) {
        let last = UserDefaults.standard.double(forKey: snapshotKey)
        let now = Date().timeIntervalSince1970
        if now - last > 6 * 3600 {
            store.keepSnapshot("presync")
            UserDefaults.standard.set(now, forKey: snapshotKey)
        }
    }
}
