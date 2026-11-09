import Foundation
import HerdrKit
import Observation
import SSHTransport
import UIKit
import UserNotifications

/// Optional Apple push alerts: gets this device's APNs token and saves it on each connected
/// machine (`~/.config/bergr/push.json`), where the host-side bergr-notify script reads it.
@MainActor @Observable
final class PushRegistration {
    static let shared = PushRegistration()
    static let key = "bergr.push.enabled"

    var enabled: Bool {
        get { access(keyPath: \.enabled); return UserDefaults.standard.bool(forKey: Self.key) }
        set {
            withMutation(keyPath: \.enabled) { UserDefaults.standard.set(newValue, forKey: Self.key) }
            if newValue { register() }
        }
    }
    /// Lowercase hex APNs token, once iOS has issued one.
    var deviceToken: String?
    var lastError: String?

    @ObservationIgnored private(set) weak var sessions: SessionStore?
    /// Per machine: which session and (token, enabled) state was last written there.
    @ObservationIgnored private var written: [UUID: (session: ObjectIdentifier, state: String)] = [:]
    @ObservationIgnored private var started = false

    private init() {}

    // MARK: Token

    nonisolated static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    func register() {
        lastError = nil
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if !granted { lastError = "Notifications are off for Bergr. Turn them on in Settings." }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(token: Data) {
        lastError = nil
        deviceToken = Self.hex(token)
    }

    func didFail(_ error: Error) { lastError = error.localizedDescription }

    // MARK: Saving on machines

    /// Starts following the sessions: saves (or removes) this device on each machine once it connects.
    func run(sessions: SessionStore) {
        guard !started else { return }
        started = true
        self.sessions = sessions
        if enabled { register() }
        observe()
    }

    private func observe() {
        let current = withObservationTracking {
            (enabled, deviceToken, (sessions?.ids ?? []).compactMap { id in
                sessions?.existing(id).map { ($0, $0.state == .connected && $0.canRunCommands) }
            })
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard let token = current.1 else { return }
        let state = "\(token)|\(current.0)"
        for (session, ready) in current.2 where ready {
            let id = session.host.id
            let identity = ObjectIdentifier(session)
            if let last = written[id], last.session == identity, last.state == state { continue }
            written[id] = (identity, state)
            let command = Self.command(token: token, enabled: current.0)
            Task { @MainActor [weak self] in
                if await Self.run(command, on: session) == false, self?.written[id]?.state == state {
                    self?.written[id] = nil
                }
            }
        }
    }

    private static func run(_ command: String, on session: HostSession) async -> Bool {
        guard let pipe = try? await session.openExec(command) else { return false }
        defer { pipe.close() }
        var out = Data()
        do { for try await chunk in pipe.output { out.append(chunk) } } catch { return false }
        return String(decoding: out, as: UTF8.self).contains("ok")
    }

    // MARK: Command

    /// What goes in the payload for this device.
    nonisolated static func payload(token: String, enabled: Bool, bundleID: String? = Bundle.main.bundleIdentifier,
                                    name: String) -> Data {
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        let device: [String: Any] = ["token": token, "bundle_id": bundleID ?? "", "sandbox": sandbox, "name": name]
        let object: [String: Any] = ["op": enabled ? "add" : "remove", "device": device]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Script and payload both travel base64-encoded, so no shell quoting can break them.
    static func command(token: String, enabled: Bool) -> String {
        command(payload: payload(token: token, enabled: enabled, name: UIDevice.current.name))
    }

    nonisolated static func command(payload: Data) -> String {
        "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' "
            + Data(mergeScript.utf8).base64EncodedString() + " " + payload.base64EncodedString()
    }

    /// Read-modify-write of push.json: sets "mode" if absent, adds or removes one device by token.
    nonisolated static let mergeScript = """
    import base64, json, os, sys, tempfile
    p = json.loads(base64.b64decode(sys.argv[1]))
    d = os.path.expanduser("~/.config/bergr")
    os.makedirs(d, mode=0o700, exist_ok=True)
    f = os.path.join(d, "push.json")
    try:
        with open(f) as fh:
            c = json.load(fh)
    except FileNotFoundError:
        c = {}
    if not isinstance(c, dict):
        raise SystemExit("push.json is not an object")
    c.setdefault("mode", "apns")
    dev = p["device"]
    devs = c.get("devices")
    devs = [x for x in devs if isinstance(x, dict)] if isinstance(devs, list) else []
    rest = [x for x in devs if x.get("token") != dev["token"]]
    c["devices"] = rest + [dev] if p["op"] == "add" else rest
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w") as fh:
        json.dump(c, fh, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, f)
    print("ok")
    """

    // MARK: Tapped pushes

    /// A push names the machine by hostname, not Bergr's id: find a session that has the terminal.
    func target(_ info: [AnyHashable: Any]) -> (host: UUID, address: String)? {
        guard let address = info["address"] as? String, let sessions else { return nil }
        let hostname = info["host"] as? String ?? ""
        let matches = sessions.ids.compactMap { sessions.existing($0) }
            .filter { $0.terminals.contains { $0.address == address } }
        let best = matches.first { $0.host.name.caseInsensitiveCompare(hostname) == .orderedSame }
            ?? matches.first { $0.state == .connected } ?? matches.first
        return best.map { ($0.host.id, address) }
    }
}

/// Receives the APNs token callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushRegistration.shared.didFail(error) }
    }
}
