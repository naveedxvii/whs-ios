import SwiftUI

@main
struct WaniShopApp: App {
    @StateObject private var store = ShopStore()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}

enum Brand {
    static let gold = Color(red: 0.72, green: 0.53, blue: 0.04)
}

struct RootView: View {
    @EnvironmentObject var store: ShopStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            StockView().tabItem { Label("Stock", systemImage: "shippingbox") }
            SellView().tabItem { Label("Sell", systemImage: "cart") }
            SalesView().tabItem { Label("Sales", systemImage: "chart.bar") }
            NavigationStack { SyncView() }.tabItem { Label("Wi-Fi sync", systemImage: "wifi") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Brand.gold)
        .onAppear { Task { await AutoSync.shared.pullIfNewer(store) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await AutoSync.shared.pullIfNewer(store) } }
        }
    }
}
