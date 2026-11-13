import SwiftUI
import Network
import UniformTypeIdentifiers
import AVFoundation

enum SyncMode {
    case none, send, receive
}

struct SyncView: View {
    @EnvironmentObject var store: ShopStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = LanBrowser()
    @State private var mode: SyncMode = .none
    @State private var message: String?
    @State private var busy = false
    @State private var manualHost = ""
    @State private var manualCode = ""
    @State private var chosen: SyncDevice?
    @State private var enteredCode = ""
    @State private var incoming: Backup?
    @State private var incomingFrom = ""
    @State private var shareFile: URL?
    @State private var showFileImporter = false
    @State private var pendingFile: URL?
    @State private var qrImages: [UIImage] = []
    @State private var showQRScanner = false

    var body: some View {
        Form {
            Section {
                Button {
                    showQRScanner = true
                } label: {
                    Label("Scan QR to receive all data", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.gold)
            }

            Section {
                HStack(spacing: 12) {
                    modeButton(title: "Send", icon: "paperplane.fill", target: .send)
                    modeButton(title: "Receive", icon: "dot.radiowaves.left.and.right", target: .receive)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if mode == .send {
                Section {
                    RadarView(devices: []) { _ in }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    Text("Scanning. Waiting for a phone to receive this data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Code: \(store.sharingCode)")
                            .font(.largeTitle).bold()
                        Text(store.deviceName).font(.subheadline)
                        if let ip = localIPAddress() {
                            Text("Address: \(ip)").font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    QRCycle(images: qrImages)
                        .frame(maxWidth: .infinity)
                } header: {
                    Text("All data as QR codes")
                } footer: {
                    Text("Keep this screen open. The other phone taps Receive, then Scan QR code (all data), and holds its camera on this code until every frame is read.")
                }
            }

            if mode == .receive {
                Section {
                    RadarView(devices: browser.devices) { device in
                        chosen = device
                        enteredCode = ""
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)

                    Text(browser.devices.isEmpty
                         ? "Searching for phones on this Wi-Fi..."
                         : "Tap a phone on the radar to receive its data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                Section {
                    TextField("Address, e.g. 192.168.1.5", text: $manualHost)
                        .keyboardType(.decimalPad)
                    TextField("Code", text: $manualCode)
                        .keyboardType(.numberPad)
                    Button("Receive from this address") {
                        let host = trimmed(manualHost)
                        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 3001)
                        receive(endpoint, code: trimmed(manualCode), name: host)
                    }
                    .disabled(busy || trimmed(manualHost).isEmpty || trimmed(manualCode).isEmpty)
                } header: {
                    Text("Android phone: type address")
                }
            }

            Section {
                Button("Prepare all data file") {
                    shareFile = store.backupFileURL()
                }
                if let shareFile {
                    ShareLink("Share all data", item: shareFile)
                }
                Button("Open a shared data file") {
                    showFileImporter = true
                }
            } header: {
                Text("Share all data")
            } footer: {
                Text("Sends stock, sales, credit and settings as one file through WhatsApp, AirDrop, Mail, or Files. On the other phone, tap Open a shared data file and pick it.")
            }

            if busy {
                Section {
                    ProgressView("Connecting...")
                }
            }
            if let message {
                Section {
                    Text(message)
                }
            }
        }
        .navigationTitle("Wi-Fi sync")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .onDisappear {
            browser.stop()
            store.stopSharing()
            qrImages = []
        }
        .sheet(item: $chosen) { device in
            NavigationStack {
                Form {
                    Section("Code shown on \(device.name)") {
                        TextField("4-digit code", text: $enteredCode)
                            .keyboardType(.numberPad)
                    }
                    Section {
                        Button("Receive") {
                            chosen = nil
                            receive(device.endpoint, code: trimmed(enteredCode), name: device.name)
                        }
                        .disabled(trimmed(enteredCode).isEmpty)
                    }
                }
                .navigationTitle("Receive")
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showQRScanner) {
            QRFrameScanner { data in
                showQRScanner = false
                receiveQR(data)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                pendingFile = url
            }
        }
        .alert("Replace this phone's stock and sales?", isPresented: Binding(
            get: { incoming != nil },
            set: { if !$0 { incoming = nil } })) {
            Button("Replace", role: .destructive) { applyIncoming() }
            Button("Cancel", role: .cancel) { incoming = nil }
        } message: {
            Text("\(incoming?.items.count ?? 0) items and \(incoming?.sales.count ?? 0) sales from \(incomingFrom) will replace what is here. A copy of the current data is kept first.")
        }
        .alert("Replace all data with this file?", isPresented: Binding(
            get: { pendingFile != nil },
            set: { if !$0 { pendingFile = nil } })) {
            Button("Replace", role: .destructive) { restoreFile() }
            Button("Cancel", role: .cancel) { pendingFile = nil }
        } message: {
            Text("Stock, sales, credit and settings from this file replace what is on this phone. A copy of the current data is kept first.")
        }
    }

    private func modeButton(title: String, icon: String, target: SyncMode) -> some View {
        let active = mode == target
        return Button {
            select(target)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(active ? Brand.gold : Brand.gold.opacity(0.15))
            .foregroundStyle(active ? Color.white : Brand.gold)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func select(_ target: SyncMode) {
        if mode == .send {
            store.stopSharing()
            qrImages = []
        }
        if mode == .receive { browser.stop() }
        if mode == target {
            mode = .none
            return
        }
        mode = target
        message = nil
        switch target {
        case .send:
            do {
                try store.startSharing()
                qrImages = QRFrames.makeImages(store.syncState.data)
            } catch {
                mode = .none
                message = "Could not start sending. Close any other app that uses port 3001 and try again."
            }
        case .receive:
            browser.start(ownName: store.deviceName)
        case .none:
            break
        }
    }

    private func receive(_ endpoint: NWEndpoint, code: String, name: String) {
        guard !code.isEmpty else {
            message = "Enter the code first."
            return
        }
        busy = true
        message = nil
        Task {
            do {
                let data = try await LanSyncClient.fetch(endpoint, code: code)
                let backup = try JSONDecoder().decode(Backup.self, from: data)
                guard !backup.items.isEmpty || !backup.sales.isEmpty else {
                    throw SyncError.empty
                }
                incoming = backup
                incomingFrom = name
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }

    /// Called when every QR frame has been read.
    private func receiveQR(_ data: Data) {
        do {
            let backup = try JSONDecoder().decode(Backup.self, from: data)
            guard !backup.items.isEmpty || !backup.sales.isEmpty else {
                throw SyncError.empty
            }
            incoming = backup
            incomingFrom = "QR code"
        } catch {
            message = "The QR codes could not be read. Try again, holding the camera steady."
        }
    }

    private func applyIncoming() {
        guard let data = incoming else { return }
        store.applySync(data)
        message = "Received \(data.items.count) items and \(data.sales.count) sales from \(incomingFrom)."
        incoming = nil
    }

    private func restoreFile() {
        guard let url = pendingFile else { return }
        pendingFile = nil
        do {
            try store.restore(from: url)
            message = "File restored: all data replaced."
        } catch {
            message = "Could not open that file: \(error.localizedDescription). Nothing was changed."
        }
    }
}

/// Shows the QR frames one after another, like a slideshow.
struct QRCycle: View {
    let images: [UIImage]
    private let interval = 0.35

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let count = images.count
            let index = count == 0 ? 0 : Int(context.date.timeIntervalSinceReferenceDate / interval) % count
            VStack(spacing: 6) {
                if count > 0 {
                    Image(uiImage: images[index])
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                    Text("Frame \(index + 1) of \(count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Preparing QR codes...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Camera screen that reads QR frames until all of the data has arrived.
struct QRFrameScanner: View {
    let onComplete: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var assembler = QRAssembler()
    @State private var status = "Hold the camera on the other phone's QR codes."

    var body: some View {
        ZStack(alignment: .bottom) {
            ScannerView(onCode: { text in handle(text) }, types: [.qr], continuous: true)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(status)
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 40)
        }
    }

    private func handle(_ text: String) {
        switch assembler.add(text) {
        case .ignored:
            break
        case .progress(let have, let total):
            status = "Read \(have) of \(total) frames. Keep the camera steady."
        case .complete(let data):
            status = "All data read."
            onComplete(data)
            dismiss()
        }
    }
}

/// Radar screen: a sweeping line, rings, and nearby phones placed around the center.
/// The sweep is computed from the clock on every frame, so it cannot get stuck.
struct RadarView: View {
    let devices: [SyncDevice]
    let onTap: (SyncDevice) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = t.truncatingRemainder(dividingBy: 2.5) / 2.5 * 360
            ZStack {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(Brand.gold.opacity(0.35), lineWidth: 1)
                        .frame(width: CGFloat(i) * 90, height: CGFloat(i) * 90)
                }

                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Brand.gold.opacity(0.55), location: 0.98),
                            .init(color: .clear, location: 1.0),
                        ]),
                        center: .center))
                    .frame(width: 270, height: 270)
                    .rotationEffect(.degrees(angle))

                ForEach(devices) { device in
                    let rad = Double(angleFor(device.name)) * .pi / 180
                    Button {
                        onTap(device)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "iphone.gen3").font(.title2)
                            Text(device.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 100)
                        }
                        .foregroundStyle(Brand.gold)
                        .padding(6)
                        .background(Color(uiColor: .systemBackground).opacity(0.95),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(cos(rad) * 95), y: CGFloat(sin(rad) * 95))
                }

                Image(systemName: "location.north.fill")
                    .foregroundStyle(Brand.gold)
            }
            .frame(width: 270, height: 270)
        }
        .frame(width: 270, height: 270)
    }

    /// Keeps each phone at the same spot on the radar, based on its name.
    private func angleFor(_ name: String) -> Int {
        var h = 0
        for scalar in name.unicodeScalars {
            h = h &* 31 &+ Int(scalar.value)
        }
        return abs(h) % 360
    }
}

/// The Wi-Fi address of this phone, so the Android phone can be typed in.
func localIPAddress() -> String? {
    var result: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let sa = ptr.pointee.ifa_addr,
              sa.pointee.sa_family == sa_family_t(AF_INET),
              String(cString: ptr.pointee.ifa_name) == "en0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST)
        result = String(cString: host)
    }
    return result
}
