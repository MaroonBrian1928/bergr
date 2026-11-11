import Foundation
import Observation

/// The Mac twin of the iOS `KeepAlive` (location session that keeps the phone running): the Mac
/// process stays alive anyway, so this only stores the "Bergr stays running" switch that shared
/// Settings and `Delivery` read.
@MainActor @Observable
final class KeepAlive {
    static let shared = KeepAlive()
    static let key = KeepAliveKey.value

    var enabled: Bool {
        get { access(keyPath: \.enabled); return UserDefaults.standard.bool(forKey: Self.key) }
        set { withMutation(keyPath: \.enabled) { UserDefaults.standard.set(newValue, forKey: Self.key) } }
    }
}
