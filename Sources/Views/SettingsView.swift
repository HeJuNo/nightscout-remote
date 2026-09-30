import SwiftUI
import os.log

private let logger = Logger(subsystem: "nightscout.kh", category: "SettingsView")

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var nightscoutURL: String = ""
    @State private var accessToken: String = ""
    @State private var saved: Bool = false
    @State private var validationError: String? = nil
    @FocusState private var urlFocused: Bool
    @FocusState private var tokenFocused: Bool
    @State private var showToken = false
    @FocusState private var newButtonFocused: Bool
    @State private var buttonStore = QuickButtonStore.shared
    @State private var newButtonValue: String = ""
    @State private var buttonError: String? = nil
    @State private var showResetConfirm = false
    @State private var editMode: EditMode = .inactive
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult? = nil
    @AppStorage(GlucoseUnit.storageKey) private var glucoseUnit: GlucoseUnit = .mgdl

    var body: some View {
        Form {
            Section(header: Text("Nightscout-Verbindung")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://mein-nightscout.example.com", text: $nightscoutURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($urlFocused)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Access Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Group {
                            if showToken {
                                TextField("z.B. khapp-1a2b3c4d5e6f7a8b", text: $accessToken)
                            } else {
                                SecureField("z.B. khapp-1a2b3c4d5e6f7a8b", text: $accessToken)
                            }
                        }
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                        .focused($tokenFocused)

                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showToken ? "Token verbergen" : "Token anzeigen")
                    }

                    if !accessToken.isEmpty && !NightscoutService.looksLikeAccessToken(accessToken) {
                        Label("Sieht nicht wie ein Nightscout Access Token aus (Format: name-1a2b3c4d5e6f7a8b). Das API-Secret funktioniert hier nicht.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let error = validationError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    saveSettings()
                } label: {
                    HStack {
                        Spacer()
                        Text("Speichern")
                            .font(.headline)
                        Spacer()
                    }
                }
            }

            if saved {
                Section {
                    Label("Einstellungen gespeichert", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            connectionTestSection

            quickButtonsSection

            Section {
                Picker("Einheit", selection: $glucoseUnit) {
                    ForEach(GlucoseUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Blutzucker")
            } footer: {
                Text("Einheit für die Blutzucker-Eingabe. Sollte zur Einstellung deiner Nightscout-Seite passen.")
            }

            Section(header: Text("Hinweis")) {
                Text("Lege in Nightscout unter Admin-Werkzeuge → Subjekt hinzufügen einen Zugang mit der Rolle „careportal“ an (Schreiben) und kopiere dessen Access Token hierher. Für den Lese-Test zusätzlich „readable“ vergeben. Der Token wird sicher im iOS-Schlüsselbund gespeichert. HTTPS wird dringend empfohlen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fertig") {
                    dismiss()
                }
            }
        }
        .onAppear {
            nightscoutURL = UserDefaults.standard.string(forKey: "nightscout_url") ?? ""
            accessToken = KeychainHelper.read(key: NightscoutService.tokenKeychainKey) ?? ""
        }
    }

    // MARK: - Connection Test

    private var connectionTestSection: some View {
        Section {
            Button {
                runConnectionTest()
            } label: {
                HStack {
                    Label("Verbindung prüfen", systemImage: "network")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)

            if let result = testResult {
                if let info = result.serverInfo {
                    LabeledContent("Server", value: info)
                        .font(.subheadline)
                }
                if let subject = result.subject {
                    LabeledContent("Zugang", value: subject)
                        .font(.subheadline)
                }
                testRow("Verbindung", status: result.reachable, detail: result.reachableDetail)
                if result.reachable == .ok {
                    testRow("Lesen", status: result.canRead, detail: result.readDetail)
                    testRow("Schreiben", status: result.canWrite, detail: result.writeDetail)
                }
            }
        } header: {
            Text("Verbindungstest")
        } footer: {
            Text("Prüft die eingegebene URL und den Access Token (auch vor dem Speichern). Es wird dabei nichts in Nightscout eingetragen.")
        }
    }

    private func testRow(_ title: String, status: ConnectionTestResult.Status, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: status))
                .foregroundStyle(color(for: status))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for status: ConnectionTestResult.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func color(for status: ConnectionTestResult.Status) -> Color {
        switch status {
        case .ok: return .green
        case .failed: return .red
        case .unknown: return .orange
        }
    }

    private func runConnectionTest() {
        let url = nightscoutURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !accessToken.isEmpty else {
            validationError = "Für den Test bitte URL und Access Token eingeben."
            return
        }
        validationError = nil
        isTesting = true
        testResult = nil
        let token = accessToken
        Task {
            let result = await NightscoutService.testConnection(urlString: url, token: token)
            testResult = result
            isTesting = false
            logger.info("Verbindungstest: reachable=\(String(describing: result.reachable)), read=\(String(describing: result.canRead)), write=\(String(describing: result.canWrite))")
        }
    }

    // MARK: - Quick Buttons

    private var quickButtonsSection: some View {
        Section {
            ForEach(Array(buttonStore.values.enumerated()), id: \.offset) { _, value in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                    Text("\(value) g KH")
                        .font(.body.weight(.semibold))
                }
            }
            .onDelete { buttonStore.remove(at: $0) }
            .onMove { buttonStore.move(from: $0, to: $1) }

            HStack {
                TextField("Neuer Wert (g)", text: $newButtonValue)
                    .keyboardType(.numberPad)
                    .focused($newButtonFocused)
                Button {
                    addButton()
                } label: {
                    Label("Hinzufügen", systemImage: "plus.circle.fill")
                }
                .disabled(newButtonValue.isEmpty)
            }

            if let buttonError {
                Text(buttonError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Button("Auf Standard zurücksetzen (2/4/6/15 g)", role: .destructive) {
                showResetConfirm = true
            }
            .confirmationDialog("Schnell-Buttons zurücksetzen?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) { buttonStore.resetToDefaults() }
                Button("Abbrechen", role: .cancel) {}
            }
        } header: {
            HStack {
                Text("Schnell-Buttons")
                Spacer()
                Button(editMode.isEditing ? "Fertig" : "Sortieren") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                .font(.caption.weight(.semibold))
                .textCase(nil)
            }
        } footer: {
            Text("Zum Löschen nach links wischen. Mit „Sortieren“ die Reihenfolge ändern. Maximal \(QuickButtonStore.maxButtons) Buttons.")
        }
    }

    private func addButton() {
        buttonError = nil
        guard let grams = Int(newButtonValue.trimmingCharacters(in: .whitespaces)), grams > 0, grams <= 500 else {
            buttonError = "Bitte eine Zahl zwischen 1 und 500 eingeben."
            return
        }
        guard buttonStore.add(grams) else {
            buttonError = "Maximal \(QuickButtonStore.maxButtons) Buttons möglich."
            return
        }
        newButtonValue = ""
        newButtonFocused = false
    }

    private func saveSettings() {
        validationError = nil
        saved = false

        let trimmedURL = nightscoutURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            validationError = "Bitte eine Nightscout-URL eingeben."
            return
        }
        let hasScheme = trimmedURL.hasPrefix("https://") || trimmedURL.lowercased().hasPrefix("http" + "://")
        guard hasScheme else {
            validationError = "Die URL muss mit https:// beginnen."
            return
        }
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            validationError = "Bitte einen Access Token eingeben."
            return
        }

        UserDefaults.standard.set(trimmedURL, forKey: "nightscout_url")
        KeychainHelper.save(key: NightscoutService.tokenKeychainKey, value: trimmedToken)
        KeychainHelper.delete(key: "api_secret") // remove legacy API secret
        logger.info("Einstellungen gespeichert.")
        saved = true
        Task { await TreatmentQueue.shared.flush() }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
