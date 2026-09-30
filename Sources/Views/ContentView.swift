import SwiftUI

struct ContentView: View {
    @State private var vm = MainViewModel()
    @State private var showSettings = false
    @FocusState private var carbFieldFocused: Bool
    @FocusState private var glucoseFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let queue = TreatmentQueue.shared

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private let buttonColors: [Color] = [
        .blue, .green, .orange, .purple
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    quickButtonGrid
                    manualEntrySection
                    glucoseSection
                    PendingQueueView(queue: queue)
                }
                .padding()
            }
            .navigationTitle("Nightscout Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                    }
                }
            }
            .overlay(alignment: .top) {
                toastBanner
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                vm.glucoseUnit = GlucoseUnit.current
            }) {
                NavigationStack {
                    SettingsView()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") {
                        carbFieldFocused = false
                        glucoseFieldFocused = false
                    }
                }
            }
            .disabled(vm.isLoading)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: queue.appBecameActive()
            case .background: queue.appEnteredBackground()
            default: break
            }
        }
    }

    // MARK: - Quick Buttons

    @ViewBuilder
    private var quickButtonGrid: some View {
        if vm.quickButtons.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Keine Schnell-Buttons")
                    .font(.headline)
                Text("Lege in den Einstellungen eigene Buttons an.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Einstellungen öffnen") { showSettings = true }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            buttonsGrid
        }
    }

    private var buttonsGrid: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(vm.quickButtons.enumerated()), id: \.offset) { index, item in
                Button {
                    vm.submitCarbs(item.grams)
                } label: {
                    Text(item.label)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(buttonColors[index % buttonColors.count])
                        )
                }
                .sensoryFeedback(.impact, trigger: vm.toastMessage)
            }
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySection: some View {
        VStack(spacing: 12) {
            Text("Manuelle Eingabe")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                TextField("Gramm KH", text: $vm.manualCarbs)
                    .keyboardType(.numberPad)
                    .focused($carbFieldFocused)
                    .font(.title3)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { carbFieldFocused = true }

                Button {
                    vm.submitManual()
                } label: {
                    Text("Eintragen")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor)
                        )
                }
            }

            if let error = vm.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            if vm.isLoading {
                ProgressView("Sende…")
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Blood glucose

    private var glucoseSection: some View {
        VStack(spacing: 12) {
            Label("Blutzucker", systemImage: "drop.fill")
                .font(.headline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                HStack {
                    TextField(vm.glucoseUnit == .mgdl ? "z.B. 120" : "z.B. 6,7", text: $vm.glucoseInput)
                        .keyboardType(vm.glucoseUnit == .mgdl ? .numberPad : .decimalPad)
                        .focused($glucoseFieldFocused)
                        .font(.title3)
                    Text(vm.glucoseUnit.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                .contentShape(Rectangle())
                .onTapGesture { glucoseFieldFocused = true }

                Button {
                    glucoseFieldFocused = false
                    vm.submitGlucose()
                } label: {
                    Text("Eintragen")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red)
                        )
                }
            }

            if let error = vm.glucoseError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Wird als Blutzucker-Messung (Finger) in Nightscout eingetragen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastBanner: some View {
        if let msg = vm.toastMessage {
            Text(msg)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(vm.toastIsWarning ? Color.orange : Color.green)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut, value: vm.toastMessage)
        }
    }
}

#Preview {
    ContentView()
}
