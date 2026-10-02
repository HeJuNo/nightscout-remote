import SwiftUI

/// Second tab: the latest carb and glucose entries this app wrote to Nightscout,
/// with swipe-to-delete.
struct HistoryView: View {
    @State private var vm = HistoryViewModel()
    @State private var pendingDelete: NightscoutTreatment?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Verlauf")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await vm.load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(vm.state == .loading)
                        .accessibilityLabel("Aktualisieren")
                    }
                }
                // Reload every time the tab becomes visible, so fresh entries show up.
                .onAppear { Task { await vm.load() } }
                .refreshable { await vm.load(showSpinner: false) }
                .confirmationDialog(
                    "Eintrag löschen?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingDelete
                ) { item in
                    Button("„\(item.displayText)“ löschen", role: .destructive) {
                        Task { await vm.delete(item) }
                    }
                    Button("Abbrechen", role: .cancel) {}
                } message: { item in
                    Text("Der Eintrag vom \(item.date.formatted(date: .abbreviated, time: .shortened)) wird endgültig aus Nightscout entfernt.")
                }
                .alert(
                    "Löschen fehlgeschlagen",
                    isPresented: Binding(
                        get: { vm.actionError != nil },
                        set: { if !$0 { vm.actionError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(vm.actionError ?? "")
                }
                .sheet(isPresented: $showSettings, onDismiss: {
                    Task { await vm.load() }
                }) {
                    NavigationStack { SettingsView() }
                }
                .sensoryFeedback(.success, trigger: vm.deleteCount)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle, .loading:
            ProgressView("Lade Einträge…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured(let message):
            ContentUnavailableView {
                Label("Nicht verbunden", systemImage: "link.badge.plus")
            } description: {
                Text(message)
            } actions: {
                Button("Einstellungen öffnen") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message) where vm.entries.isEmpty:
            ContentUnavailableView {
                Label("Laden fehlgeschlagen", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut versuchen") { Task { await vm.load() } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            if vm.entries.isEmpty {
                ContentUnavailableView(
                    "Noch keine Einträge",
                    systemImage: "list.bullet.rectangle",
                    description: Text("KH- und Blutzucker-Einträge dieser App aus den letzten 30 Tagen erscheinen hier.")
                )
            } else {
                entryList
            }
        }
    }

    private var entryList: some View {
        List {
            if case .failed(let message) = vm.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if vm.canDelete == false {
                Section {
                    Label("Dein Access Token darf keine Einträge löschen. Dafür ist das Recht „api:treatments:delete“ nötig (z.B. Rolle „admin“).",
                          systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(vm.sections, id: \.day) { section in
                Section(dayTitle(section.day)) {
                    ForEach(section.items) { item in
                        HistoryRow(item: item, isDeleting: vm.deletingIDs.contains(item.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    pendingDelete = item
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Zeigt die Einträge dieser App aus den letzten 30 Tagen. Zum Löschen nach links wischen.")
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: vm.entries)
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Heute" }
        if cal.isDateInYesterday(day) { return "Gestern" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct HistoryRow: View {
    let item: NightscoutTreatment
    let isDeleting: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isGlucose ? "drop.fill" : "fork.knife")
                .font(.title3)
                .foregroundStyle(item.isGlucose ? .red : .blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(.headline)
                Text(item.isGlucose ? "Blutzucker (Finger)" : "Kohlenhydrate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDeleting {
                ProgressView()
            } else {
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HistoryView()
}
