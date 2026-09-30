import SwiftUI
import QuotioMobile

/// Settings tab: connection, display and about, in short grouped sections.
struct SettingsScreen: View {
    @Environment(HostStore.self) private var store
    @Binding var addHost: Bool
    @State private var computerToRemove: HostProfile?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach(store.state.hosts) { host in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(host.name).font(DS.Typography.accountTitle)
                        Text(verbatim: host.origin.host ?? "").font(DS.Typography.caption).foregroundStyle(.secondary)
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: "lock.fill").accessibilityHidden(true)
                            Text(host.certificate == nil ? "System certificate trust" : "Paired certificate trusted")
                        }
                        .font(DS.Typography.caption).foregroundStyle(.secondary)
                        if let expiration = host.expiresAt {
                            Text("Access expires \(expiration.formatted(date: .abbreviated, time: .omitted))")
                                .font(DS.Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Remove computer", systemImage: "trash", role: .destructive) { computerToRemove = host }
                    }
                    .contextMenu {
                        Button("Remove computer", systemImage: "trash", role: .destructive) { computerToRemove = host }
                    }
                }
                Button("Add computer", systemImage: "plus") { addHost = true }
            } header: {
                Text("Connection")
            } footer: {
                Text("Removing a computer deletes its saved credential on this iPhone. Revoke the device on the computer to end its access everywhere.")
            }

            Section("Display") {
                Toggle("Blur account names", isOn: $store.state.blurAccountNames)
                Toggle("Show used percentage", isOn: $store.state.showUsed)
                Toggle("Lowest quota first", isOn: $store.state.lowFirst)
                Picker("Density", selection: $store.state.density) {
                    Text("Comfortable").tag(Density.comfortable)
                    Text("Compact").tag(Density.compact)
                }
                if let providers = store.selected?.snapshot?.sections(order: store.state.providerOrder, lowFirst: false, pinned: []),
                   providers.count > 1 {
                    NavigationLink("Provider order") { ProviderOrderScreen(providers: providers.map { .init(id: $0.providerID, name: $0.providerName) }) }
                        .disabled(store.state.lowFirst)
                }
            }
            .onChange(of: store.state.blurAccountNames) { store.persist() }
            .onChange(of: store.state.showUsed) { store.persist() }
            .onChange(of: store.state.lowFirst) { store.persist() }
            .onChange(of: store.state.density) { store.persist() }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text("Provider credentials stay on your Mac. This iPhone reads quota over HTTPS with read-only access.")
                    .font(DS.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this computer?", isPresented: Binding(
            get: { computerToRemove != nil }, set: { if !$0 { computerToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove computer", role: .destructive) {
                if let computerToRemove { store.remove(computerToRemove.id) }
                computerToRemove = nil
            }
            Button("Cancel", role: .cancel) { computerToRemove = nil }
        } message: {
            Text(computerToRemove?.name ?? "")
        }
    }
}

/// Drag to reorder provider sections on the Usage tab.
struct ProviderOrderScreen: View {
    @Environment(HostStore.self) private var store
    @State var providers: [ProviderFilterBar.Option]

    var body: some View {
        List {
            ForEach(providers) { provider in
                Label { Text(provider.name) } icon: { ProviderIcon(providerID: provider.id).foregroundStyle(.secondary) }
            }
            .onMove { from, to in
                providers.move(fromOffsets: from, toOffset: to)
                store.state.providerOrder = providers.map(\.id)
                store.persist()
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Provider order")
        .navigationBarTitleDisplayMode(.inline)
    }
}
