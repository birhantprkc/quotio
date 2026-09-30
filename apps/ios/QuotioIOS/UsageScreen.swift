import SwiftUI
import QuotioMobile

/// Usage tab: compact top bar, one connection banner when unhealthy, provider
/// filter chips and provider sections of account cards.
struct UsageScreen: View {
    @Environment(HostStore.self) private var store
    @Binding var accountID: String?
    @Binding var addHost: Bool
    @State private var filter: String?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var showIssue = false
    @State private var revealedAccountIDs: Set<String> = []

    var body: some View {
        Group {
            if let host = store.selected {
                dashboard(host)
            } else {
                onboarding
            }
        }
        .navigationTitle("Quotio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onDisappear { revealedAccountIDs.removeAll() }
        .sheet(isPresented: $showIssue) {
            if let issue = store.currentIssue {
                ConnectionIssueSheet(issue: issue, lastSync: store.selected?.snapshot?.receivedAt,
                                     retry: { Task { await store.refresh() } }, pair: { addHost = true })
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let host = store.selected {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(store.state.hosts) { host in
                        Button(host.name) { accountID = nil; filter = nil; store.select(host.id) }
                    }
                    Divider()
                    Button("Add computer", systemImage: "plus") { addHost = true }
                } label: {
                    ConnectionChip(name: host.name, state: chipState(host))
                }
            }
        }
        if store.selected == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add computer", systemImage: "plus") { addHost = true }
            }
        }
    }

    private func chipState(_ host: HostProfile) -> ConnectionChip.State {
        switch store.currentIssue {
        case .busy?: .degraded
        case .some: .offline
        case nil: host.snapshot == nil ? .connecting : .healthy
        }
    }

    @ViewBuilder private func dashboard(_ host: HostProfile) -> some View {
        let layout = DS.Layout.of(store.state.density)
        let sections = host.snapshot?.sections(order: store.state.providerOrder, lowFirst: store.state.lowFirst,
                                               pinned: host.pinnedAccountIDs) ?? []
        let visible = sections.filter { filter == nil || $0.providerID == filter }
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    VStack(alignment: .leading, spacing: layout.sectionSpacing) {
                        if let issue = store.currentIssue {
                            ConnectionBanner(title: issue.title, lastSync: host.snapshot?.receivedAt,
                                             actionTitle: issue.needsPairing ? "Pair again" : "Retry",
                                             action: { if issue.needsPairing { addHost = true } else { Task { await store.refresh() } } },
                                             showDetails: { showIssue = true })
                        }
                        if let snapshot = host.snapshot {
                            if snapshot.accounts.isEmpty {
                                ContentUnavailableView("No accounts", systemImage: "person.crop.circle",
                                                       description: Text("Add an account in Quotio on your Mac."))
                            }
                            ForEach(visible) { section in
                                providerSection(section, host: host, spacing: layout.cardSpacing)
                            }
                        } else if store.currentIssue == nil {
                            ProgressView().frame(maxWidth: .infinity).padding(DS.Space.xxl)
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.top, DS.Space.s)
                    .padding(.bottom, DS.Space.xl)
                } header: {
                    // A pinned header rather than a safe-area bar: a horizontal ScrollView inside
                    // safeAreaInset/safeAreaBar does not draw its content on iOS 26.
                    if sections.count > 1 {
                        ProviderFilterBar(options: sections.map { .init(id: $0.providerID, name: $0.providerName) }, selection: $filter)
                            .background {
                                // Fade cards out beneath the pinned chips instead of showing them between chips.
                                DS.Palette.background
                                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .ignoresSafeArea(edges: .top)
                            }
                    }
                }
            }
        }
        .scrollPosition($scrollPosition)
        .onChange(of: filter) { scrollPosition.scrollTo(edge: .top) }
        .background(DS.Palette.background)
        .refreshable { await store.refresh() }
        .environment(\.density, store.state.density)
        .onChange(of: sections.map(\.providerID)) { _, ids in
            if let filter, !ids.contains(filter) { self.filter = nil }
        }
    }

    @ViewBuilder private func providerSection(_ section: MobileSnapshot.ProviderSection, host: HostProfile, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ProviderSectionHeader(providerID: section.providerID, name: section.providerName)
            ForEach(section.accounts) { account in
                let title = account.identity != nil || section.accounts.count > 1 ? account.name : nil
                let blurAccountName = store.state.blurAccountNames && !revealedAccountIDs.contains(account.id)
                Button { accountID = account.id } label: {
                    if account.hasData {
                        AccountCard(account: account, title: title, blurAccountName: blurAccountName,
                                    showUsed: store.state.showUsed, accountNameToggleEnabled: store.state.blurAccountNames,
                                    toggleAccountName: { toggleAccountName(account.id) })
                    } else {
                        EmptyAccountRow(title: title, reason: account.emptyReason,
                                        blurAccountName: blurAccountName, accountNameToggleEnabled: store.state.blurAccountNames,
                                        toggleAccountName: { toggleAccountName(account.id) })
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows account details"))
                .contextMenu {
                    let pinned = host.pinnedAccountIDs.contains(account.id)
                    Button(pinned ? "Unpin account" : "Pin account", systemImage: pinned ? "pin.slash" : "pin") {
                        store.togglePin(account.id)
                    }
                }
            }
        }
    }

    private func toggleAccountName(_ id: String) {
        guard store.state.blurAccountNames else { return }
        if revealedAccountIDs.remove(id) == nil { revealedAccountIDs.insert(id) }
    }

    private var onboarding: some View {
        ContentUnavailableView {
            Label("Your quota, in your pocket", systemImage: "chart.pie")
        } description: {
            Text(store.currentIssue?.title ?? String(localized: "Connect to Quotio on your Mac to see usage and add widgets."))
        } actions: {
            Button("Add computer") { addHost = true }.buttonStyle(.borderedProminent)
            Button("Explore demo") { store.showDemo() }
        }
    }
}
