import SwiftUI

struct SalesView: View {
    @EnvironmentObject var store: ShopStore
    @State private var confirmUndo = false
    @State private var selected: Sale?

    private var today: ShopStore.Summary {
        store.summary(since: Calendar.current.startOfDay(for: Date()))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    Text("\(today.bills) bills · sales \(store.money(today.sales)) · profit \(store.money(today.profit))")
                    Button("Undo last sale", role: .destructive) { confirmUndo = true }
                        .disabled(store.backup.sales.isEmpty)
                }

                Section {
                    NavigationLink("Customer credit") { CreditView() }
                }

                Section("Recent sales") {
                    ForEach(store.backup.sales.reversed().prefix(40)) { sale in
                        Button { selected = sale } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("Bill \(sale.no)").bold()
                                    Spacer()
                                    Text(store.money(sale.total)).bold()
                                }
                                Text(Date(timeIntervalSince1970: sale.t)
                                    .formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                let who = sale.contact.isEmpty ? sale.cust : "\(sale.cust) · \(sale.contact)"
                                Text(who).font(.caption)
                                Text(sale.lines.map { "\($0.n) x\($0.q)" }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Sales")
            .sheet(item: $selected) { sale in
                BillView(sale: sale)
            }
            .confirmationDialog("Undo the last sale? Its stock goes back on the shelf.",
                                isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("Undo last sale", role: .destructive) { _ = store.undoLastSale() }
            }
        }
    }
}

struct CreditView: View {
    @EnvironmentObject var store: ShopStore
    @State private var amounts: [String: String] = [:]
    @State private var message: String?

    var body: some View {
        let rows = store.creditRows()
        List {
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name).bold()
                            Text(row.contact).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Due \(store.money(row.due))").bold()
                    }
                    HStack {
                        TextField("Amount received", text: Binding(
                            get: { amounts[row.id] ?? "" },
                            set: { amounts[row.id] = $0 }))
                            .keyboardType(.decimalPad)
                        Button("Receive") { receive(row) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }
            if rows.isEmpty {
                Text("No pending credit.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Customer credit")
    }

    private func receive(_ row: ShopStore.CreditRow) {
        guard let amt = Double(trimmed(amounts[row.id] ?? "")), amt > 0 else {
            message = "Enter the amount received."
            return
        }
        let applied = store.receiveCredit(row, amount: amt)
        amounts[row.id] = ""
        message = "Received \(store.money(applied)) from \(row.name)."
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: ShopStore
    @State private var shopName = ""
    @State private var currency = ""
    @State private var footer = ""
    @State private var paper = ""
    @State private var lowDefault = ""
    @State private var nextNo = ""
    @State private var upi = ""
    @State private var message: String?
    @State private var backupFile: URL?
    @State private var csvFile: URL?
    @State private var showImporter = false
    @State private var pendingRestore: URL?
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            Form {
                GoogleDriveSection()
                Section("Shop") {
                    TextField("Shop name", text: $shopName)
                    TextField("Currency symbol", text: $currency)
                    TextField("Bill footer", text: $footer)
                    TextField("Paper width (mm)", text: $paper).keyboardType(.decimalPad)
                    TextField("Default low stock alert", text: $lowDefault).keyboardType(.numberPad)
                    TextField("Next bill number", text: $nextNo).keyboardType(.numberPad)
                    Button("Save settings") { saveSettings() }
                }

                Section("UPI payment") {
                    TextField("name@bank", text: $upi)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save UPI ID") { saveUPI() }
                }

                Section("This month") {
                    let s = store.summary(since: ShopStore.monthStart)
                    Text("\(s.bills) bills · sales \(store.money(s.sales)) · profit \(store.money(s.profit))")
                    ForEach(store.topSellers(since: ShopStore.monthStart), id: \.name) { t in
                        Text("\(t.name) — \(t.qty)")
                    }
                }

                Section("Backup and export") {
                    Button("Prepare backup file") { backupFile = store.backupFileURL() }
                    if let backupFile {
                        ShareLink("Share backup (JSON)", item: backupFile)
                    }
                    Button("Prepare stock list (CSV)") { csvFile = store.csvFileURL() }
                    if let csvFile {
                        ShareLink("Share stock (CSV)", item: csvFile)
                    }
                    Button("Restore from backup file") { showImporter = true }
                }

                Section("Danger zone") {
                    Button("Erase all stock and sales", role: .destructive) { confirmErase = true }
                }

                Section("About") {
                    Text("Version 1.0")
                    Text("Created by Naveed Fayaz")
                    Text("© 2026 Naveed Fayaz. All rights reserved.").font(.footnote)
                }

                if let message {
                    Section { Text(message) }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadFields)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): pendingRestore = url
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert("Replace all stock and sales with this backup?", isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } })) {
                Button("Restore", role: .destructive) { restore() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Erase all stock and sales? A copy is kept first.",
                                isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    store.eraseAll()
                    message = "All stock and sales erased."
                }
            }
        }
    }

    private func loadFields() {
        shopName = store.setting("shop_name")
        currency = store.setting("currency")
        footer = store.setting("footer")
        paper = store.setting("paper_mm")
        lowDefault = store.setting("low_default")
        nextNo = store.setting("next_no")
        upi = store.setting("upi_id")
    }

    private func saveSettings() {
        guard let p = Double(trimmed(paper)), (40...600).contains(p) else {
            message = "Paper width must be between 40 and 600 mm."
            return
        }
        guard let n = Int(trimmed(nextNo)), n >= 1 else {
            message = "Next bill number must be 1 or more."
            return
        }
        guard let low = Int(trimmed(lowDefault)), low >= 0 else {
            message = "Low stock alert must be 0 or more."
            return
        }
        let shop = trimmed(shopName)
        store.setSetting("shop_name", shop.isEmpty ? "Wani Hardware Store" : shop)
        store.setSetting("currency", trimmed(currency))
        store.setSetting("footer", trimmed(footer))
        store.setSetting("paper_mm", String(format: "%g", p))
        store.setSetting("low_default", String(low))
        store.setSetting("next_no", String(n))
        message = "Settings saved."
    }

    private func saveUPI() {
        let v = trimmed(upi)
        if !v.isEmpty && (!v.contains("@") || v.contains(" ")) {
            message = "UPI ID should look like name@bank, with no spaces."
            return
        }
        store.setSetting("upi_id", v)
        message = v.isEmpty ? "UPI ID removed." : "UPI ID saved."
    }

    private func restore() {
        guard let url = pendingRestore else { return }
        pendingRestore = nil
        do {
            try store.restore(from: url)
            loadFields()
            message = "Backup restored."
        } catch {
            message = "Restore failed: \(error.localizedDescription). Nothing was changed."
        }
    }
}
