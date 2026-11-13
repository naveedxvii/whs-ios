import SwiftUI
import AVFoundation

struct StockView: View {
    @EnvironmentObject var store: ShopStore
    @State private var query = ""
    @State private var lowOnly = false
    @State private var editing: Item?
    @State private var adding = false

    private var lowDefault: Int { Int(store.setting("low_default")) ?? 2 }

    private func isLow(_ item: Item) -> Bool {
        item.qty <= (item.low ?? lowDefault)
    }

    private var shown: [Item] {
        let q = query.lowercased()
        return store.backup.items.values
            .filter { item in
                let hay = "\(item.barcode) \(item.name) \(item.cat)".lowercased()
                let matches = q.isEmpty || hay.contains(q)
                return matches && (!lowOnly || isLow(item))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let items = store.backup.items.values
                    let units = items.reduce(0) { $0 + $1.qty }
                    let value = items.reduce(0.0) { $0 + Double($1.qty) * $1.price }
                    Text("\(items.count) items · \(units) units · value \(store.money(value))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(shown) { item in
                        ItemRow(item: item, low: isLow(item))
                            .contentShape(Rectangle())
                            .onTapGesture { editing = item }
                    }
                    if shown.isEmpty {
                        Text("No items found.").foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search name, barcode or category")
            .navigationTitle("Stock")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lowOnly ? "Show all" : "Low stock") { lowOnly.toggle() }
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    ItemForm(existing: nil)
                }
            }
            .sheet(item: $editing) { item in
                NavigationStack {
                    ItemForm(existing: item)
                }
            }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var store: ShopStore
    let item: Item
    let low: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.headline)
                    if low {
                        Text("LOW")
                            .font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(Color.red)
                            .clipShape(Capsule())
                    }
                }
                let sub = item.cat.isEmpty ? item.barcode : "\(item.barcode) · \(item.cat)"
                Text(sub).font(.caption).foregroundStyle(.secondary)
                Text(store.money(item.price)).font(.subheadline)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { store.adjust(item.barcode, by: -1) } label: {
                    Image(systemName: "minus.circle").font(.title2)
                }
                Text("\(item.qty)").font(.headline).frame(minWidth: 32)
                Button { store.adjust(item.barcode, by: 1) } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct AddItemView: View {
    var body: some View {
        NavigationStack {
            ItemForm(existing: nil)
        }
    }
}

struct ItemForm: View {
    @EnvironmentObject var store: ShopStore
    @Environment(\.dismiss) private var dismiss

    let existing: Item?
    @State private var barcode: String
    @State private var name: String
    @State private var price: String
    @State private var cost: String
    @State private var addQty = "0"
    @State private var low: String
    @State private var cat: String
    @State private var message: String?
    @State private var showScanner = false
    @State private var labelsURL: URL?
    @State private var confirmDelete = false

    init(existing: Item?) {
        self.existing = existing
        _barcode = State(initialValue: existing?.barcode ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _price = State(initialValue: existing.map { String($0.price) } ?? "")
        _cost = State(initialValue: existing.map { $0.cost == 0 ? "" : String($0.cost) } ?? "")
        _low = State(initialValue: existing?.low.map { String($0) } ?? "")
        _cat = State(initialValue: existing?.cat ?? "")
    }

    var body: some View {
        Form {
            Section("Barcode") {
                TextField("Barcode", text: $barcode)
                    .keyboardType(.numberPad)
                    .disabled(existing != nil)
                HStack {
                    Button { showScanner = true } label: {
                        Label("Scan", systemImage: "barcode.viewfinder")
                    }
                    if existing == nil {
                        Spacer()
                        Button("New barcode") { barcode = store.newBarcode() }
                    }
                }
                if let code = validEAN(barcode) {
                    Image(uiImage: eanImage(code))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 90)
                        .frame(maxWidth: .infinity)
                }
            }

            Section("Item") {
                TextField("Name", text: $name)
                TextField("Price", text: $price).keyboardType(.decimalPad)
                TextField("Cost (optional)", text: $cost).keyboardType(.decimalPad)
                TextField("Quantity to add", text: $addQty).keyboardType(.numberPad)
                TextField("Low stock alert at (optional)", text: $low).keyboardType(.numberPad)
                TextField("Category (optional)", text: $cat)
            }

            if let message {
                Section {
                    Text(message).foregroundStyle(Brand.gold)
                }
            }

            Section {
                Button("Save item") { save() }
                    .frame(maxWidth: .infinity)
                    .bold()
            }

            if let existing {
                Section("More") {
                    Button("Make 12 labels (PDF)") {
                        labelsURL = Printables.labelsPDF(existing, count: 12, store: store)
                    }
                    if let labelsURL {
                        ShareLink("Share labels PDF", item: labelsURL)
                    }
                    Button("Delete item", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(existing == nil ? "Add item" : "Edit item")
        .sheet(isPresented: $showScanner) {
            ScannerSheet { code in
                barcode = code
                showScanner = false
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deleteItem(barcode)
                dismiss()
            }
        }
    }

    private func save() {
        let typed = trimmed(barcode)
        let bc = validEAN(typed) ?? (typed.isEmpty ? store.newBarcode() : typed)
        let itemName = trimmed(name)
        guard !itemName.isEmpty, let p = Double(trimmed(price)), p >= 0 else {
            message = "Enter a name and a valid price."
            return
        }
        let c = Double(trimmed(cost)) ?? 0
        guard let q = Int(trimmed(addQty)), q >= 0 else {
            message = "Quantity to add must be 0 or more."
            return
        }
        let lowValue = trimmed(low).isEmpty ? nil : Int(trimmed(low))

        message = store.saveItem(barcode: bc, name: itemName, price: p, cost: c,
                                 addQty: q, low: lowValue, cat: trimmed(cat))
        if existing != nil {
            dismiss()
        } else {
            barcode = ""; name = ""; price = ""; cost = ""; addQty = "0"; low = ""; cat = ""
        }
    }
}

struct ScannerSheet: View {
    let onCode: (String) -> Void
    var types: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            ScannerView(onCode: onCode, types: types).ignoresSafeArea()
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
        }
    }
}

struct ScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var types: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
    var continuous = false

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        vc.types = types
        vc.continuous = continuous
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}
