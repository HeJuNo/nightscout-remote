import Foundation
import Observation
import Network
import UIKit
import os.log

private let logger = Logger(subsystem: "nightscout.kh", category: "TreatmentQueue")

/// A carb entry waiting to be uploaded. `createdAtString` is fixed at tap time,
/// so a delayed upload still lands at the moment the carbs were entered.
struct PendingTreatment: Codable, Identifiable, Equatable {
    let id: UUID
    let carbs: Int
    let createdAt: Date
    let createdAtString: String
    var attempts: Int
    var lastError: String?
    /// Set for blood glucose entries (then `carbs` is 0). Optional so older queue data still decodes.
    var glucose: Double? = nil
    var glucoseUnit: GlucoseUnit? = nil

    var isGlucose: Bool { glucose != nil }

    var displayText: String {
        if let glucose, let unit = glucoseUnit {
            return "BZ \(unit.format(glucose)) \(unit.label)"
        }
        return "\(carbs) g KH"
    }
}

/// Blood glucose unit, chosen in the settings.
enum GlucoseUnit: String, Codable, CaseIterable, Identifiable {
    case mgdl
    case mmol

    static let storageKey = "glucose_unit"

    var id: String { rawValue }
    var label: String { self == .mgdl ? "mg/dL" : "mmol/L" }
    /// Value for the Nightscout `units` field (as sent by the Careportal).
    var nightscoutValue: String { self == .mgdl ? "mg/dl" : "mmol" }
    var validRange: ClosedRange<Double> { self == .mgdl ? 20...600 : 1.1...33.3 }

    func format(_ value: Double) -> String {
        self == .mgdl
            ? String(Int(value.rounded()))
            : value.formatted(.number.precision(.fractionLength(1)))
    }

    static var current: GlucoseUnit {
        GlucoseUnit(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .mgdl
    }
}

enum SendOutcome {
    case sent
    case queued(String)
}

/// Persistent upload queue. Every entry is stored BEFORE the upload starts, so nothing
/// is lost if the app is closed or the network is down. Uploads run inside an iOS
/// background task so they can finish after the app leaves the foreground.
@MainActor
@Observable
final class TreatmentQueue {
    static let shared = TreatmentQueue()

    private(set) var items: [PendingTreatment] = []
    private(set) var isFlushing = false

    @ObservationIgnored private let storageKey = "pending_treatments"
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {
        load()
        startNetworkMonitor()
    }

    // MARK: - Public API

    func enqueueAndSend(_ grams: Int) async -> SendOutcome {
        let now = Date()
        let item = PendingTreatment(
            id: UUID(),
            carbs: grams,
            createdAt: now,
            createdAtString: ISO8601DateFormatter.nightscoutFormatter.string(from: now),
            attempts: 0,
            lastError: nil
        )
        logger.info("Enqueued \(grams)g (queue size \(self.items.count + 1))")
        return await enqueueAndSend(item: item)
    }

    func enqueueAndSendGlucose(_ value: Double, unit: GlucoseUnit) async -> SendOutcome {
        let now = Date()
        let item = PendingTreatment(
            id: UUID(),
            carbs: 0,
            createdAt: now,
            createdAtString: ISO8601DateFormatter.nightscoutFormatter.string(from: now),
            attempts: 0,
            lastError: nil,
            glucose: value,
            glucoseUnit: unit
        )
        logger.info("Enqueued BG \(value) \(unit.label) (queue size \(self.items.count + 1))")
        return await enqueueAndSend(item: item)
    }

    private func enqueueAndSend(item: PendingTreatment) async -> SendOutcome {
        items.append(item)
        save()

        await flush()

        if let still = items.first(where: { $0.id == item.id }) {
            return .queued(still.lastError ?? "Unbekannter Fehler")
        }
        return .sent
    }

    /// Uploads all pending entries in order. Stops at the first failure (keeps order).
    func flush() async {
        while isFlushing {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !items.isEmpty else { return }

        isFlushing = true
        beginBackgroundTask()
        defer {
            isFlushing = false
            endBackgroundTask()
        }

        let ids = items.map(\.id)
        for (position, id) in ids.enumerated() {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            do {
                try await NightscoutService.postTreatment(item)
                items.removeAll { $0.id == id }
                save()
                logger.info("Uploaded \(item.displayText) from \(item.createdAtString)")
            } catch {
                let message = error.localizedDescription
                logger.error("Upload failed, keeping in queue: \(message)")
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].attempts += 1
                    items[idx].lastError = message
                }
                // Mark the remaining (not attempted) entries with the same reason.
                for rest in ids.dropFirst(position + 1) {
                    if let idx = items.firstIndex(where: { $0.id == rest }) {
                        items[idx].lastError = message
                    }
                }
                save()
                break
            }
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Called on scene phase changes.
    func appBecameActive() {
        Task { await flush() }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if !self.items.isEmpty { await self.flush() }
            }
        }
    }

    func appEnteredBackground() {
        retryTask?.cancel()
        retryTask = nil
        if !items.isEmpty {
            Task { await flush() }
        }
    }

    // MARK: - Background task

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "NightscoutUpload") { [weak self] in
            MainActor.assumeIsolated {
                logger.info("Background time expired – remaining entries stay queued")
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Network

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.items.isEmpty else { return }
                logger.info("Network available – retrying queue")
                await self.flush()
            }
        }
        monitor.start(queue: DispatchQueue(label: "nightscout.kh.network"))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PendingTreatment].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
