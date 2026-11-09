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

    /// A machine that needs the helper installed or updated, waiting for the user's answer.
    struct PendingInstall {
        let session: HostSession
        let hostName: String
        let isUpdate: Bool
    }
    enum HelperState: Equatable { case current, missing, outdated, installing }
    var pendingInstall: PendingInstall?
    /// What the last check found on each machine, for Settings.
    private(set) var helperState: [UUID: HelperState] = [:]
    static let declinedKey = "bergr.push.declined"

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
            let enabled = current.0
            Task { @MainActor [weak self] in
                if await Self.run(command, on: session) == false {
                    if self?.written[id]?.state == state { self?.written[id] = nil }
                    return
                }
                if enabled { await self?.checkHelper(on: session) } else { await self?.removeHelper(on: session) }
            }
        }
    }

    private static func run(_ command: String, on session: HostSession) async -> Bool {
        await output(command, on: session)?.contains("ok") ?? false
    }

    private static func output(_ command: String, on session: HostSession) async -> String? {
        guard let pipe = try? await session.openExec(command) else { return nil }
        defer { pipe.close() }
        var out = Data()
        do { for try await chunk in pipe.output { out.append(chunk) } } catch { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Helper service

    private static let bundledScript: String? = Bundle.main.url(forResource: "bergr-notify", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let installer: String? = Bundle.main.url(forResource: "install-helper", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The `VERSION = n` line of a bergr-notify.py source.
    nonisolated static func version(in source: String) -> Int? {
        guard let match = source.firstMatch(of: /(?m)^VERSION\s*=\s*(\d+)/) else { return nil }
        return Int(match.1)
    }

    static var bundledVersion: Int? { bundledScript.flatMap { version(in: $0) } }

    nonisolated static func declinedHosts(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: declinedKey) ?? [])
    }

    nonisolated static func setDeclined(_ declined: Bool, host: UUID, defaults: UserDefaults = .standard) {
        var set = declinedHosts(defaults)
        if declined { set.insert(host.uuidString) } else { set.remove(host.uuidString) }
        defaults.set(set.sorted(), forKey: declinedKey)
    }

    /// The command that runs install-helper.py with these arguments on the machine.
    nonisolated static func installerCommand(installer: String, op: String, script: String? = nil) -> String {
        var object: [String: Any] = ["op": op]
        if let script { object["script"] = script }
        let args = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' "
            + Data(installer.utf8).base64EncodedString() + " " + args.base64EncodedString()
    }

    private static func helperResult(_ op: String, script: String? = nil, on session: HostSession) async -> [String: Any]? {
        guard let installer else { return nil }
        let command = installerCommand(installer: installer, op: op, script: script)
        guard let out = await output(command, on: session) else { return nil }
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// Asks once (per machine) to install or update the helper when it is missing or older than the bundled one.
    private func checkHelper(on session: HostSession) async {
        guard let bundled = Self.bundledVersion, let status = await Self.helperResult("status", on: session) else { return }
        let id = session.host.id
        let installed = status["installed"] as? Bool ?? false
        let version = status["version"] as? Int
        if installed, let version, version >= bundled {
            helperState[id] = .current
            return
        }
        helperState[id] = installed ? .outdated : .missing
        guard enabled, pendingInstall == nil, !Self.declinedHosts().contains(id.uuidString) else { return }
        pendingInstall = PendingInstall(session: session, hostName: session.host.name, isUpdate: installed)
    }

    private func removeHelper(on session: HostSession) async {
        helperState[session.host.id] = nil
        _ = await Self.helperResult("uninstall", on: session)
    }

    /// Installs (or updates) the helper after the user agreed.
    func install(on session: HostSession) async {
        let id = session.host.id
        let name = session.host.name
        guard let script = Self.bundledScript else {
            lastError = "Couldn't install the push helper on \(name): the helper is missing from the app."
            return
        }
        let before = helperState[id]
        helperState[id] = .installing
        let result = await Self.helperResult("install", script: script, on: session)
        if result?["ok"] as? Bool == true {
            lastError = nil
            helperState[id] = .current
        } else {
            helperState[id] = before
            let reason = result?["error"] as? String ?? "no answer from the machine"
            lastError = "Couldn't install the push helper on \(name): \(reason)"
        }
    }

    func decline(_ pending: PendingInstall) {
        Self.setDeclined(true, host: pending.session.host.id)
    }

    /// Settings' Install button: clears an earlier "Not now" and installs right away.
    func installFromSettings(on session: HostSession) {
        Self.setDeclined(false, host: session.host.id)
        Task { await install(on: session) }
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
