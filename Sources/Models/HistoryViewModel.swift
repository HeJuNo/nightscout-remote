import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "nightscout.kh", category: "History")

/// Loads and deletes the entries this app wrote to Nightscout.
@Observable
@MainActor
final class HistoryViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case notConfigured(String)
        case failed(String)
    }

    private(set) var entries: [NightscoutTreatment] = []
    private(set) var state: LoadState = .idle
    private(set) var deletingIDs: Set<String> = []
    /// Nil = unknown, false = token lacks `api:treatments:delete`.
    private(set) var canDelete: Bool? = nil
    var actionError: String?
    private(set) var deleteCount = 0

    /// Entries grouped by calendar day, newest day first.
    var sections: [(day: Date, items: [NightscoutTreatment])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: entries) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.date > $1.date })
        }
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner && entries.isEmpty { state = .loading }
        do {
            let items = try await NightscoutService.fetchAppTreatments()
            entries = items
            state = .loaded
            canDelete = await NightscoutService.deletePermitted()
            logger.info("History loaded: \(items.count) entries, canDelete \(String(describing: self.canDelete))")
        } catch let error as NightscoutError {
            switch error {
            case .noURL, .noToken:
                entries = []
                state = .notConfigured(error.localizedDescription)
            default:
                state = .failed(error.localizedDescription)
            }
            logger.error("History load failed: \(error.localizedDescription)")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("History load failed: \(error.localizedDescription)")
        }
    }

    func delete(_ item: NightscoutTreatment) async {
        guard !deletingIDs.contains(item.id) else { return }
        deletingIDs.insert(item.id)
        defer { deletingIDs.remove(item.id) }
        do {
            try await NightscoutService.deleteTreatment(id: item.id)
            entries.removeAll { $0.id == item.id }
            deleteCount += 1
            logger.info("Deleted treatment \(item.id)")
        } catch {
            actionError = error.localizedDescription
            if case NightscoutError.deleteForbidden = error { canDelete = false }
            logger.error("Delete failed: \(error.localizedDescription)")
        }
    }
}
