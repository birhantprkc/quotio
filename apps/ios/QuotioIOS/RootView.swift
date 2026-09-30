import SwiftUI
import QuotioMobile

struct RootView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var addHost = false
    @State private var accountID: String?

    var body: some View {
        TabView(selection: $tab) {
            Tab("Usage", systemImage: "chart.pie.fill", value: 0) {
                NavigationStack {
                    UsageScreen(accountID: $accountID, addHost: $addHost)
                        .navigationDestination(item: $accountID) { id in
                            if let host = store.selected, let account = host.snapshot?.account(id) {
                                AccountDetailScreen(account: account, blurAccountName: store.state.blurAccountNames,
                                                    showUsed: store.state.showUsed,
                                                    pinned: host.pinnedAccountIDs.contains(account.id),
                                                    togglePin: { store.togglePin(account.id) })
                            } else {
                                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.questionmark")
                            }
                        }
                }
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: 1) {
                NavigationStack { SettingsScreen(addHost: $addHost) }
            }
        }
        .tint(DS.Palette.accent)
        .sheet(isPresented: $addHost) { PairHostView() }
        .task(id: "\(scenePhase)-\(store.state.selectedHostID ?? "")") {
            guard scenePhase == .active else { store.suspend(); return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(store.issue == nil ? 30 : 60)) }
                catch { return }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "quotio", url.host == "account", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let host = components.queryItems?.first(where: { $0.name == "host" })?.value,
                  let account = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  store.state.hosts.contains(where: { $0.id == host }) else { return }
            store.select(host); tab = 0; accountID = account
        }
    }
}

#if DEBUG
#Preview("Demo") {
    RootView().environment({ let store = HostStore(storage: nil); store.showDemo(); return store }())
}

#Preview("Demo · VI · Dark") {
    RootView()
        .environment({ let store = HostStore(storage: nil); store.showDemo(); return store }())
        .environment(\.locale, Locale(identifier: "vi"))
        .preferredColorScheme(.dark)
}

#Preview("Offline") {
    RootView().environment({ let store = HostStore(storage: nil); store.showDemo(); store.issue = .unreachable; return store }())
}

#Preview("Empty") {
    RootView().environment(HostStore(storage: nil))
}
#endif
