import SwiftUI

struct SellView: View {
    @EnvironmentObject var store: ShopStore
    @State private var codeInput = ""
    @State private var query = ""
    @State private var showScanner = false
    @State private var customer = ""
    @State private var contact = ""
    @State private var discount = ""
    @State private var paid = ""
    @State private var method = "cash"
    @State private var bill: Sale?
    @State private var errorText: String?

    private var results: [Item] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return store.backup.items.values
            .filter { $0.name.lowercased().contains(q) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private var upiID: String { store.setting("upi_id") }

    private var netAmount: Double {
        max(store.cartTotal - (Double(trimmed(discount)) ?? 0), 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add item") {
                    HStack {
                        TextField("Type barcode", text: $codeInput)
                            .keyboardType(.numberPad)
                            .onSubmit { addCode(codeInput); codeInput = "" }
                        Button("Add") { addCode(codeInput); codeInput = "" }
                        Button { showScanner = true } label: {
                            Image(systemName: "barcode.viewfinder").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                    TextField("Search by name", text: $query)
                    ForEach(results) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("\(store.money(item.price)) · \(item.qty) left")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { showError(store.addToCart(item.barcode)) }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Bill") {
                    if store.cartLines.isEmpty {
                        Text("Bill is empty").foregroundStyle(.secondary)
                    }
                    ForEach(store.cartLines) { line in
                        HStack {
                            Text(line.item.name).lineLimit(1)
                            Spacer()
                            Button { showError(store.changeCart(line.item.barcode, by: -1)) } label: {
                                Image(systemName: "minus.circle")
                            }
                            Text("\(line.qty)").frame(minWidth: 24)
                            Button { showError(store.changeCart(line.item.barcode, by: 1)) } label: {
                                Image(systemName: "plus.circle")
                            }
                            Text(store.money(line.sub))
                                .frame(minWidth: 70, alignment: .trailing)
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Text("Total").bold()
                        Spacer()
                        Text(store.money(netAmount)).bold()
                    }
                    if !upiID.isEmpty, !store.cart.isEmpty {
                        let link = upiLink(vpa: upiID, name: store.setting("shop_name"),
                                           amount: netAmount, note: "Bill")
                        Image(uiImage: qrImage(link) ?? UIImage())
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160)
                            .frame(maxWidth: .infinity)
                    }
                }

                Section("Customer and payment") {
                    TextField("Customer name (optional)", text: $customer)
                    TextField("Contact (optional)", text: $contact)
                    Picker("Paid by", selection: $method) {
                        Text("Cash").tag("cash")
                        Text("Online (UPI)").tag("online")
                    }
                    TextField("Amount received (blank = full; less = credit)", text: $paid)
                        .keyboardType(.decimalPad)
                    TextField("Discount", text: $discount)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button("Complete sale") { checkout() }
                        .disabled(store.cart.isEmpty)
                        .frame(maxWidth: .infinity)
                        .bold()
                    Button("Clear bill", role: .destructive) { store.cart = [:] }
                        .disabled(store.cart.isEmpty)
                }
            }
            .navigationTitle("Sell")
            .sheet(isPresented: $showScanner) {
                ScannerSheet { code in
                    showScanner = false
                    showError(store.addToCart(code))
                }
            }
            .sheet(item: $bill) { sale in
                BillView(sale: sale)
            }
            .alert("Sell", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func addCode(_ raw: String) {
        let t = trimmed(raw)
        guard !t.isEmpty else { return }
        showError(store.addToCart(t))
    }

    private func showError(_ message: String?) {
        if let message { errorText = message }
    }

    private func checkout() {
        let disc = Double(trimmed(discount)) ?? 0
        var paidIn: Double?
        let paidText = trimmed(paid)
        if !paidText.isEmpty {
            guard let p = Double(paidText) else {
                errorText = "Enter amounts as numbers."
                return
            }
            paidIn = p
        }
        do {
            let sale = try store.checkout(customer: customer, contact: contact,
                                          discount: disc, paidIn: paidIn, method: method)
            bill = sale
            customer = ""; contact = ""; discount = ""; paid = ""
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct BillView: View {
    @EnvironmentObject var store: ShopStore
    @Environment(\.dismiss) private var dismiss
    let sale: Sale
    @State private var pdf: URL?

    private var subtotal: Double {
        sale.lines.reduce(0.0) { $0 + $1.p * Double($1.q) }
    }

    private var dateText: String {
        Date(timeIntervalSince1970: sale.t).formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Text(store.setting("shop_name")).font(.title2).bold()
                    Text("Bill #\(sale.no)")
                    Text(dateText).font(.caption).foregroundStyle(.secondary)
                    if !sale.cust.isEmpty { Text(sale.cust) }
                    if !sale.contact.isEmpty { Text(sale.contact).font(.caption) }
                    Divider()
                    ForEach(Array(sale.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(line.n)
                                Text("\(line.q) x \(store.money(line.p))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(store.money(line.p * Double(line.q)))
                        }
                    }
                    Divider()
                    HStack { Text("Subtotal"); Spacer(); Text(store.money(subtotal)) }
                    if sale.disc > 0 {
                        HStack { Text("Discount"); Spacer(); Text("-" + store.money(sale.disc)) }
                    }
                    HStack { Text("Total").bold(); Spacer(); Text(store.money(sale.total)).bold() }
                    Text(store.setting("footer")).font(.footnote).foregroundStyle(.secondary)

                    let upi = store.setting("upi_id")
                    if !upi.isEmpty, sale.total > 0,
                       let qr = qrImage(upiLink(vpa: upi, name: store.setting("shop_name"),
                                                amount: sale.total, note: "Bill \(sale.no)")) {
                        Divider()
                        Text("Scan to pay \(store.money(sale.total))").font(.caption)
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180)
                    }
                }
                .padding()
            }
            .navigationTitle("Bill #\(sale.no)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let pdf {
                        ShareLink(item: pdf)
                    }
                }
            }
            .task {
                pdf = Printables.billPDF(sale, store: store)
            }
        }
    }
}
