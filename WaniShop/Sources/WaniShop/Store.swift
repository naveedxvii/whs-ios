import Foundation
import Combine

@MainActor
final class ShopStore: ObservableObject {
    @Published var backup: Backup
    @Published var cart: [String: Int] = [:]
    @Published var sharingCode = ""
    var isApplyingRemote = false
    let syncState: SyncState
    let server: LanSyncServer

    struct CartLine: Identifiable {
        let item: Item
        let qty: Int
        var id: String { item.barcode }
        var sub: Double { item.price * Double(qty) }
    }

    struct Summary {
        var bills: Int
        var sales: Double
        var profit: Double
    }

    struct CustKey: Hashable {
        let cust: String
        let contact: String
    }

    struct CreditRow: Identifiable {
        let key: CustKey
        let name: String
        let contact: String
        let due: Double
        var id: String { key.cust + "|" + key.contact }
    }

    enum SaleError: LocalizedError {
        case emptyBill
        case stock(String)
        case creditNeedsCustomer

        var errorDescription: String? {
            switch self {
            case .emptyBill: return "Bill is empty."
            case .stock(let name): return "Not enough stock for \(name)."
            case .creditNeedsCustomer: return "For credit, enter the customer name and contact."
            }
        }
    }

    enum RestoreError: LocalizedError {
        case noItems
        var errorDescription: String? { "That backup has no items." }
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var dataFileURL: URL {
        documentsURL.appendingPathComponent("wani-data.json")
    }

    static var monthStart: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    }

    init() {
        let state = SyncState()
        syncState = state
        server = LanSyncServer(state: state)
        var loaded = Backup()
        if let d = try? Data(contentsOf: Self.dataFileURL),
           let b = try? JSONDecoder().decode(Backup.self, from: d) {
            loaded = b
        }
        for key in loaded.items.keys {
            loaded.items[key]?.barcode = key
        }
        for (k, v) in defaultSettings where loaded.settings[k] == nil {
            loaded.settings[k] = v
        }
        backup = loaded
    }

    // MARK: - Settings and saving

    func setting(_ key: String) -> String {
        backup.settings[key] ?? defaultSettings[key] ?? ""
    }

    var currency: String { setting("currency") }

    func money(_ n: Double) -> String {
        formatMoney(n, currency: currency)
    }

    func setSetting(_ key: String, _ value: String) {
        backup.settings[key] = value
        save()
    }

    func save() {
        if let d = try? JSONEncoder().encode(backup) {
            try? d.write(to: Self.dataFileURL, options: .atomic)
        }
        syncState.data = (try? JSONEncoder().encode(backup)) ?? Data()
        if !isApplyingRemote { AutoSync.shared.changed(self) }
    }

    // MARK: - Stock

    func newBarcode() -> String {
        var seq = Int(setting("seq")) ?? 0
        var code = ""
        repeat {
            seq += 1
            let base = "28" + String(format: "%010d", seq)
            code = base + String(eanCheckDigit(base))
        } while backup.items[code] != nil
        setSetting("seq", String(seq))
        return code
    }

    func saveItem(barcode bc: String, name: String, price: Double, cost: Double,
                  addQty: Int, low: Int?, cat: String) -> String {
        if backup.items[bc] != nil {
            backup.items[bc]?.name = name
            backup.items[bc]?.price = price
            backup.items[bc]?.cost = cost
            backup.items[bc]?.qty += addQty
            backup.items[bc]?.low = low
            backup.items[bc]?.cat = cat
            save()
            return "Updated \(name). Now \(backup.items[bc]?.qty ?? 0) in stock."
        }
        backup.items[bc] = Item(barcode: bc, name: name, price: price, cost: cost,
                                qty: addQty, low: low, cat: cat)
        save()
        return "Saved \(name)."
    }

    func adjust(_ bc: String, by delta: Int) {
        guard let current = backup.items[bc] else { return }
        backup.items[bc]?.qty = max(0, current.qty + delta)
        save()
    }

    func deleteItem(_ bc: String) {
        backup.items[bc] = nil
        save()
    }

    // MARK: - Cart and checkout

    var cartLines: [CartLine] {
        cart.compactMap { bc, n -> CartLine? in
            guard let item = backup.items[bc] else { return nil }
            return CartLine(item: item, qty: n)
        }
        .sorted { $0.item.name.lowercased() < $1.item.name.lowercased() }
    }

    var cartTotal: Double {
        cartLines.reduce(0) { $0 + $1.sub }
    }

    /// Returns an error message, or nil when the item was added.
    func addToCart(_ raw: String) -> String? {
        let bc = validEAN(raw) ?? trimmed(raw)
        guard let item = backup.items[bc] else { return "Item not found." }
        let have = cart[bc] ?? 0
        if have + 1 > item.qty { return "No more in stock." }
        cart[bc] = have + 1
        return nil
    }

    func changeCart(_ bc: String, by delta: Int) -> String? {
        let have = cart[bc] ?? 0
        if delta > 0, let item = backup.items[bc], have + delta > item.qty {
            return "No more in stock."
        }
        let n = have + delta
        cart[bc] = n > 0 ? n : nil
        return nil
    }

    func checkout(customer: String, contact: String, discount: Double,
                  paidIn: Double?, method: String) throws -> Sale {
        guard !cart.isEmpty else { throw SaleError.emptyBill }

        var lines: [SaleLine] = []
        var total = 0.0
        var cost = 0.0
        for (bc, n) in cart {
            guard let item = backup.items[bc], item.qty >= n else {
                throw SaleError.stock(backup.items[bc]?.name ?? bc)
            }
            total += item.price * Double(n)
            cost += item.cost * Double(n)
            lines.append(SaleLine(bc: bc, n: item.name, q: n, p: item.price))
        }

        let disc = min(max(discount, 0), total)
        let net = total - disc
        let cust = trimmed(customer)
        let con = trimmed(contact)
        if let p = paidIn, p < net, cust.isEmpty {
            throw SaleError.creditNeedsCustomer
        }

        var name = cust
        if name.isEmpty {
            let seq = (Int(setting("cust_seq")) ?? 0) + 1
            setSetting("cust_seq", String(seq))
            name = "Customer #\(seq)"
        }

        let no = Int(setting("next_no")) ?? 1
        for line in lines {
            backup.items[line.bc]?.qty -= line.q
        }
        let paid = paidIn.map { min(max($0, 0), net) } ?? net
        let sale = Sale(no: no, t: Date().timeIntervalSince1970, total: net, disc: disc,
                        profit: net - cost, lines: lines, cust: name, contact: con,
                        paid: paid, method: method)
        backup.sales.append(sale)
        cart = [:]
        setSetting("next_no", String(no + 1))
        save()
        return sale
    }

    func undoLastSale() -> Bool {
        guard let last = backup.sales.popLast() else { return false }
        for line in last.lines {
            backup.items[line.bc]?.qty += line.q
        }
        save()
        return true
    }

    // MARK: - Reports

    func summary(since start: Date) -> Summary {
        let s = start.timeIntervalSince1970
        let rows = backup.sales.filter { $0.t >= s }
        return Summary(bills: rows.count,
                       sales: rows.reduce(0) { $0 + $1.total },
                       profit: rows.reduce(0) { $0 + $1.profit })
    }

    func topSellers(since start: Date, limit: Int = 5) -> [(name: String, qty: Int)] {
        var counts: [String: Int] = [:]
        for sale in backup.sales where sale.t >= start.timeIntervalSince1970 {
            for line in sale.lines {
                counts[line.n, default: 0] += line.q
            }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (name: $0.key, qty: $0.value) }
    }

    // MARK: - Credit

    func creditRows() -> [CreditRow] {
        var owed: [CustKey: Double] = [:]
        var names: [CustKey: String] = [:]
        var contacts: [CustKey: String] = [:]

        for sale in backup.sales {
            let key = CustKey(cust: trimmed(sale.cust).lowercased(),
                              contact: trimmed(sale.contact).lowercased())
            let due = sale.total - (sale.paid ?? sale.total)
            if due > 0.005 {
                owed[key, default: 0] += due
                if names[key] == nil { names[key] = trimmed(sale.cust) }
                if contacts[key] == nil { contacts[key] = trimmed(sale.contact) }
            }
        }
        for p in backup.payments {
            let key = CustKey(cust: trimmed(p.cust).lowercased(),
                              contact: trimmed(p.contact).lowercased())
            owed[key, default: 0] -= p.amount
        }

        return owed.compactMap { pair -> CreditRow? in
            let key = pair.key
            let v = pair.value
            guard v > 0.005, !key.cust.isEmpty else { return nil }
            return CreditRow(key: key,
                             name: names[key] ?? key.cust,
                             contact: contacts[key] ?? key.contact,
                             due: v)
        }
        .sorted { $0.due > $1.due }
    }

    func receiveCredit(_ row: CreditRow, amount: Double) -> Double {
        let applied = min(amount, row.due)
        guard applied > 0 else { return 0 }
        backup.payments.append(Payment(cust: row.key.cust, contact: row.key.contact,
                                       amount: applied,
                                       t: Date().timeIntervalSince1970, method: "cash"))
        save()
        return applied
    }

    // MARK: - Backup, export and restore

    private func writeTemp(_ data: Data, _ name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func backupFileURL() -> URL? {
        var b = backup
        b.format = 2
        b.created = Date().timeIntervalSince1970
        b.shop = setting("shop_name")
        guard let data = try? JSONEncoder().encode(b) else { return nil }
        return writeTemp(data, "wani-backup-\(dayStamp()).json")
    }

    func csvFileURL() -> URL? {
        var out = "barcode,name,price,quantity\n"
        let sorted = backup.items.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for it in sorted {
            out += "\(it.barcode),\(csvEscape(it.name)),\(it.price),\(it.qty)\n"
        }
        return writeTemp(Data(out.utf8), "stock.csv")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// Saves the current data to Documents before a destructive change.
    func keepSnapshot(_ label: String) {
        guard let data = try? JSONEncoder().encode(backup) else { return }
        let name = "\(label)-\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: Self.documentsURL.appendingPathComponent(name))
    }

    func restore(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        var incoming = try JSONDecoder().decode(Backup.self, from: data)
        guard !incoming.items.isEmpty else { throw RestoreError.noItems }

        keepSnapshot("prerestore")
        for key in incoming.items.keys {
            incoming.items[key]?.barcode = key
        }
        for (k, v) in defaultSettings where incoming.settings[k] == nil {
            incoming.settings[k] = v
        }
        backup.items = incoming.items
        backup.sales = incoming.sales
        backup.payments = incoming.payments
        backup.settings = incoming.settings
        cart = [:]
        save()
        SyncMerge.forget()
    }

    func eraseAll() {
        keepSnapshot("preerase")
        backup.items = [:]
        backup.sales = []
        backup.payments = []
        cart = [:]
        backup.settings["next_no"] = "1"
        backup.settings["cust_seq"] = "0"
        save()
    }
}
