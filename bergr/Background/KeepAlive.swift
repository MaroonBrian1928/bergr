import CoreLocation
import Foundation
import Observation
import UserNotifications

/// Keeps the app running in the background (like SSH clients do) by holding a low-accuracy
/// location session, so sessions stay connected and alerts can be posted.
@MainActor @Observable
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()
    static let key = "bergr.keepConnectedInBackground"

    var enabled: Bool {
        get { access(keyPath: \.enabled); return UserDefaults.standard.bool(forKey: Self.key) }
        set {
            withMutation(keyPath: \.enabled) { UserDefaults.standard.set(newValue, forKey: Self.key) }
            if newValue { requestPermissions() } else { stop() }
        }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var running = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    private func requestPermissions() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            manager.requestAlwaysAuthorization()
            if inBackground { start() }
        }
    }

    func appEnteredBackground() {
        inBackground = true
        if enabled { start() }
    }

    func appEnteredForeground() {
        inBackground = false
        stop()
    }

    private func start() {
        guard !running else { return }
        running = true
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.showsBackgroundLocationIndicator = false
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
