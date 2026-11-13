import Foundation

/// Three-way merge for Wani Shop data. These are the same rules as syncmerge.py on Android,
/// so both phones reach the same result.
///
///   base   = the shared copy this phone agreed on the last time it synced (nil if never)
///   local  = what is on this phone now
///   remote = the copy in Google Drive now (nil if there is no file yet)
///
/// - Stock quantity is merged as a change: qty = local + remote - base.
/// - Item name/price/cost/low/cat: a phone's own edit wins, otherwise the other phone's edit.
/// - Sales and payments are merged by their unique id. A sale deleted (undo) on either phone
///   since the base is removed.
/// - If two different sales have the same bill number, the later one is renumbered.
/// - Counters (next_no, seq, cust_seq) take the highest value.

/// Sales made before unique ids existed get the same id on every phone.
func legacySaleUid(no: Int, t: Double) -> String {
    let secs = t > 1e11 ? t / 1000 : t
    return "L\(no)-\(Int(secs))"
}

struct MergeState: Codable {
    var items: [String: Item] = [:]
    var sales: [Sale] = []
    var payments: [Payment] = []
    var settings: [String: String] = [:]
}

struct MergeReport {
    var conflicts: [String] = []
    var renumbered: [(uid: String, old: Int, new: Int)] = []
}

private struct SyncBaseFile: Codable {
    var rev: String?
    var state: MergeState
}

private struct SyncPendingFile: Codable {
    var rev: String
    var merged: MergeState
    var remote0: MergeState?
}

enum SyncMerge {
    static let counters = ["next_no", "seq", "cust_seq"]
    // Printer width, auto-print etc. stay different on each phone.
    static let sharedSettings = ["shop_name", "currency", "footer", "low_default"] + counters

    // MARK: - The merge

    static func merge(base: MergeState?, local: MergeState, remote: MergeState?) -> (MergeState, MergeReport) {
        var report = MergeReport()
        guard let remote else {
            return (cleaned(local), report)
        }
        let items = mergeItems(base: base?.items, local: local.items, remote: remote.items, report: &report)
        var sales = mergeRecords(base: base?.sales, local: local.sales, remote: remote.sales) { $0.uid }
        let renumbered = renumber(sales, report: &report)
        sales = renumbered.sales
        var payments = mergeRecords(base: base?.payments, local: local.payments, remote: remote.payments) { $0.id }
        payments.sort { ($0.t, $0.id) < ($1.t, $1.id) }
        var settings = mergeSettings(base: base?.settings, local: local.settings, remote: remote.settings)
        let next = max(num(settings["next_no"], default: 1), renumbered.top + 1)
        settings["next_no"] = String(next)
        return (MergeState(items: items, sales: sales, payments: payments, settings: settings), report)
    }

    private static func num(_ s: String?, default d: Int = 0) -> Int {
        guard let s else { return d }
        if let i = Int(s) { return i }
        if let f = Double(s) { return Int(f) }
        return d
    }

    private static func sameFields(_ a: Item, _ b: Item) -> Bool {
        a.name == b.name && a.price == b.price && a.cost == b.cost && a.low == b.low && a.cat == b.cat
    }

    private static func mergeItems(base: [String: Item]?, local: [String: Item], remote: [String: Item],
                                   report: inout MergeReport) -> [String: Item] {
        var keys = Set(local.keys).union(remote.keys)
        if let base { keys.formUnion(base.keys) }
        var out: [String: Item] = [:]
        for bc in keys.sorted() {
            let b = base?[bc]
            let l = local[bc]
            let r = remote[bc]
            if let l, let r {
                var m = r
                if let b {
                    m.name = l.name != b.name ? l.name : r.name
                    m.price = l.price != b.price ? l.price : r.price
                    m.cost = l.cost != b.cost ? l.cost : r.cost
                    m.low = l.low != b.low ? l.low : r.low
                    m.cat = l.cat != b.cat ? l.cat : r.cat
                    m.qty = max(0, l.qty + r.qty - b.qty)
                } else if l.qty != r.qty || !sameFields(l, r) {
                    // Never synced before, or added on both phones: Drive's copy is used.
                    report.conflicts.append(bc)
                }
                m.barcode = bc
                out[bc] = m
            } else if let l {
                // Only here. If the other phone deleted it and this phone did not touch it, delete.
                if let b, sameFields(l, b), l.qty == b.qty { continue }
                var m = l
                m.barcode = bc
                out[bc] = m
            } else if let r {
                if let b, sameFields(r, b), r.qty == b.qty { continue }
                var m = r
                m.barcode = bc
                out[bc] = m
            }
        }
        return out
    }

    private static func mergeRecords<T: Encodable>(base: [T]?, local: [T], remote: [T],
                                                   key: (T) -> String) -> [T] {
        var L: [String: T] = [:]
        for x in local { L[key(x)] = x }
        var R: [String: T] = [:]
        for x in remote { R[key(x)] = x }
        var B: [String: T]?
        if let base {
            var d: [String: T] = [:]
            for x in base { d[key(x)] = x }
            B = d
        }
        var out: [T] = []
        for k in Set(L.keys).union(R.keys) {
            if let B, let b = B[k] {
                // Deleted on one phone since the last sync.
                guard let l = L[k], let r = R[k] else { continue }
                out.append(sameJSON(l, b) ? r : l)
            } else if let l = L[k] {
                out.append(l)
            } else if let r = R[k] {
                out.append(r)
            }
        }
        return out
    }

    private static func renumber(_ sales: [Sale], report: inout MergeReport) -> (sales: [Sale], top: Int) {
        var list = sales.sorted { ($0.t, $0.uid) < ($1.t, $1.uid) }
        var top = list.map { $0.no }.max() ?? 0
        var seen = Set<Int>()
        for i in list.indices {
            let no = list[i].no
            if seen.contains(no) {
                top += 1
                report.renumbered.append((uid: list[i].uid, old: no, new: top))
                list[i].no = top
                seen.insert(top)
            } else {
                seen.insert(no)
            }
        }
        return (list, top)
    }

    private static func mergeSettings(base: [String: String]?, local: [String: String],
                                      remote: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for k in sharedSettings {
            let vals = [base?[k], local[k], remote[k]].compactMap { $0 }.filter { !$0.isEmpty }
            if counters.contains(k) {
                if !vals.isEmpty { out[k] = String(vals.map { num($0) }.max() ?? 0) }
                continue
            }
            let l = local[k]
            let r = remote[k]
            let pick: String?
            if let base {
                pick = l != base[k] ? l : r
            } else {
                pick = (r != nil && r != "") ? r : l
            }
            if let pick { out[k] = pick }
        }
        return out
    }

    private static func cleaned(_ s: MergeState) -> MergeState {
        var out = s
        out.sales.sort { ($0.t, $0.uid) < ($1.t, $1.uid) }
        out.payments.sort { ($0.t, $0.id) < ($1.t, $1.id) }
        out.settings = s.settings.filter { sharedSettings.contains($0.key) }
        return out
    }

    // MARK: - Comparing

    private static func sameJSON<T: Encodable>(_ a: T, _ b: T) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let x = try? enc.encode(a), let y = try? enc.encode(b) else { return false }
        return x == y
    }

    private static func sameRecords<T: Encodable>(_ a: [T], _ b: [T], key: (T) -> String) -> Bool {
        guard a.count == b.count else { return false }
        var m: [String: T] = [:]
        for x in b { m[key(x)] = x }
        for x in a {
            guard let y = m[key(x)], sameJSON(x, y) else { return false }
        }
        return true
    }

    /// True when two states hold the same shared data (order does not matter).
    static func sameContent(_ a: MergeState, _ b: MergeState) -> Bool {
        guard a.items.count == b.items.count else { return false }
        for (k, x) in a.items {
            guard let y = b.items[k], x.qty == y.qty, sameFields(x, y) else { return false }
        }
        guard sameRecords(a.sales, b.sales, key: { $0.uid }),
              sameRecords(a.payments, b.payments, key: { $0.id }) else { return false }
        for k in sharedSettings where a.settings[k] != b.settings[k] {
            return false
        }
        return true
    }

    // MARK: - Turning a backup into merge data and back

    static func state(from b: Backup) -> MergeState {
        var items = b.items
        for k in items.keys { items[k]?.barcode = k }
        return MergeState(items: items, sales: b.sales, payments: b.payments, settings: b.settings)
    }

    // MARK: - What this phone remembers between syncs

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var baseURL: URL { dir.appendingPathComponent("wani-sync-base.json") }
    private static var pendingURL: URL { dir.appendingPathComponent("wani-sync-pending.json") }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        if let d = try? JSONEncoder().encode(value) {
            try? d.write(to: url, options: .atomic)
        }
    }

    /// Used after a full replace (restore, Wi-Fi/QR receive): the next sync starts fresh.
    static func forget() {
        try? FileManager.default.removeItem(at: baseURL)
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// This phone's data now equals the shared copy.
    static func saveBase(_ state: MergeState, rev: String?) {
        write(SyncBaseFile(rev: rev, state: state), to: baseURL)
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// If the Drive copy includes our last upload (it is that upload, or a later merge built on
    /// it), our upload is the shared starting point. Otherwise it never arrived, and the copy we
    /// merged with is the one everybody still shares.
    static func resolveBase(lineage: Set<String>) -> MergeState? {
        if let pend: SyncPendingFile = read(pendingURL) {
            return lineage.contains(pend.rev) ? pend.merged : pend.remote0
        }
        let saved: SyncBaseFile? = read(baseURL)
        return saved?.state
    }

    /// Builds the file to upload and remembers it, so a failed upload can be sorted out later.
    static func exportForUpload(_ merged: MergeState, remote0: MergeState?, lineage: [String]) -> Data? {
        let rev = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        var b = Backup()
        b.format = 3
        b.created = Date().timeIntervalSince1970
        b.shop = merged.settings["shop_name"] ?? ""
        b.items = merged.items
        b.sales = merged.sales
        b.payments = merged.payments
        b.settings = merged.settings
        b.rev = rev
        b.revs = Array(lineage.suffix(400))
        guard let data = try? JSONEncoder().encode(b) else { return nil }
        write(SyncPendingFile(rev: rev, merged: merged, remote0: remote0), to: pendingURL)
        return data
    }
}
