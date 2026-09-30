import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "nightscout.kh", category: "MainViewModel")

@Observable
final class MainViewModel {
    var manualCarbs: String = ""
    var glucoseInput: String = ""
    var glucoseError: String? = nil
    var glucoseUnit: GlucoseUnit = .current
    var isLoading: Bool = false
    var toastMessage: String? = nil
    var errorMessage: String? = nil
    var toastIsWarning: Bool = false

    let buttonStore = QuickButtonStore.shared

    var quickButtons: [(label: String, grams: Int)] {
        buttonStore.values.map { ("\($0)g", $0) }
    }

    func submitCarbs(_ grams: Int) {
        guard grams > 0 else { return }
        isLoading = true
        errorMessage = nil
        toastMessage = nil

        Task { @MainActor in
            let outcome = await TreatmentQueue.shared.enqueueAndSend(grams)
            manualCarbs = ""
            isLoading = false
            let message: String
            switch outcome {
            case .sent:
                logger.info("Erfolgreich: \(grams)g KH eingetragen")
                message = "✓ \(grams)g KH eingetragen"
                toastIsWarning = false
            case .queued(let reason):
                logger.error("In Warteschlange: \(reason)")
                message = "⏳ \(grams)g KH gespeichert – wird nachgeholt"
                toastIsWarning = true
                // Reason is shown once, in the queue list below – not duplicated here.
            }
            toastMessage = message
            try? await Task.sleep(for: .seconds(3))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func submitGlucose() {
        let unit = GlucoseUnit.current
        glucoseUnit = unit
        let normalized = glucoseInput
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), unit.validRange.contains(value) else {
            glucoseError = "Bitte einen Wert zwischen \(unit.format(unit.validRange.lowerBound)) und \(unit.format(unit.validRange.upperBound)) \(unit.label) eingeben."
            return
        }
        glucoseError = nil
        errorMessage = nil
        isLoading = true
        toastMessage = nil
        let text = "\(unit.format(value)) \(unit.label)"

        Task { @MainActor in
            let outcome = await TreatmentQueue.shared.enqueueAndSendGlucose(value, unit: unit)
            glucoseInput = ""
            isLoading = false
            let message: String
            switch outcome {
            case .sent:
                logger.info("Erfolgreich: BZ \(text) eingetragen")
                message = "✓ BZ \(text) eingetragen"
                toastIsWarning = false
            case .queued(let reason):
                logger.error("BZ in Warteschlange: \(reason)")
                message = "⏳ BZ \(text) gespeichert – wird nachgeholt"
                toastIsWarning = true
            }
            toastMessage = message
            try? await Task.sleep(for: .seconds(3))
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func submitManual() {
        guard let grams = Int(manualCarbs), grams > 0 else {
            errorMessage = "Bitte eine gültige Zahl eingeben."
            return
        }
        submitCarbs(grams)
    }
}
