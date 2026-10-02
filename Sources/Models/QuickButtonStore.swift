import Foundation
import Observation

/// Persists the user-defined quick-button values (grams) in UserDefaults.
@Observable
final class QuickButtonStore {
    static let shared = QuickButtonStore()
    static let defaultValues: [Int] = [2, 4, 6, 14]
    static let maxButtons = 12

    private let key = "quick_button_values"

    var values: [Int] {
        didSet { UserDefaults.standard.set(values, forKey: key) }
    }

    private init() {
        if let stored = UserDefaults.standard.array(forKey: key) as? [Int] {
            values = stored
        } else {
            values = QuickButtonStore.defaultValues
        }
    }

    @discardableResult
    func add(_ grams: Int) -> Bool {
        guard grams > 0, values.count < QuickButtonStore.maxButtons else { return false }
        values.append(grams)
        return true
    }

    func remove(at offsets: IndexSet) {
        values.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        values.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        values = QuickButtonStore.defaultValues
    }
}
