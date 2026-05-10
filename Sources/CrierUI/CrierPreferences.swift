import Foundation
import Combine

enum CrierPreferenceKeys {
    static let compactOverlay = "crierCompactOverlay"
}

/// Shared app preferences backed by `UserDefaults`. Use one instance from
/// `AppDelegate` and pass into SwiftUI so menu toggles and overlay layout stay
/// in sync (unlike raw `defaults write` + `@AppStorage` alone).
@MainActor
final class CrierPreferences: ObservableObject {
    @Published var compactOverlay: Bool {
        didSet {
            guard !suppressPersistence else { return }
            UserDefaults.standard.set(compactOverlay, forKey: CrierPreferenceKeys.compactOverlay)
        }
    }

    private var suppressPersistence = false

    init() {
        compactOverlay = UserDefaults.standard.bool(forKey: CrierPreferenceKeys.compactOverlay)
    }

    /// Call after `CRIER_COMPACT_OVERLAY` or other tools mutate `UserDefaults`
    /// before this object was created — normally unnecessary because the env
    /// hook runs before `AppDelegate` instantiates this type.
    func reloadFromUserDefaults() {
        let v = UserDefaults.standard.bool(forKey: CrierPreferenceKeys.compactOverlay)
        guard v != compactOverlay else { return }
        suppressPersistence = true
        compactOverlay = v
        suppressPersistence = false
    }
}
