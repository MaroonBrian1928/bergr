import CryptoKit
import Foundation
import HerdrKit
import Observation
import SSHTransport
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif
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
            // macOS (Delivery.helperSupported is false there) keeps the flag but never registers.
            if newValue { if Delivery.helperSupported { register() } } else { unregisterFromRelay() }
        }
    }
    /// Whether the helpers send this phone notifications (Settings → Notifications). Off, they
    /// still keep the Live Activity current. Mirrors `Delivery.notifications`.
    private(set) var alerts = UserDefaults.standard.object(forKey: Delivery.notificationsKey) as? Bool ?? true
    func alertsChanged() { if alerts != Delivery.notifications { alerts = Delivery.notifications } }
    /// Lowercase hex APNs token, once iOS has issued one.
    var deviceToken: String?
    var lastError: String?

    /// A machine that needs the helper installed or updated, waiting for the user's answer.
    struct PendingInstall: Identifiable {
        let session: HostSession
        let hostName: String
        let isUpdate: Bool
        var id: UUID { session.host.id }
    }
    enum HelperState: Equatable { case checking, current, missing, outdated, installing, failed(String), unsupported(String) }

    /// Machines waiting for an answer, first in first out, one machine at most once.
    struct InstallQueue<Item: Identifiable> where Item.ID == UUID {
        private(set) var items: [Item] = []
        var first: Item? { items.first }
        @discardableResult
        mutating func enqueue(_ item: Item) -> Bool {
            guard !items.contains(where: { $0.id == item.id }) else { return false }
            items.append(item)
            return true
        }
        mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
        @discardableResult
        mutating func pop() -> Item? { items.isEmpty ? nil : items.removeFirst() }
    }
    private(set) var installQueue = InstallQueue<PendingInstall>()
    /// The machine the prompt is about now.
    var pendingInstall: PendingInstall? { installQueue.first }
    /// True while Settings is on screen; it then shows the prompt itself.
    var settingsOpen = false
    /// Shown once an install or update finished, so the tap has a visible result.
    var finishedMessage: String?
    /// What the last check found on each machine, for Settings.
    private(set) var helperState: [UUID: HelperState] = [:]
    /// The helper version installed on each machine, as it last reported it.
    private(set) var helperVersion: [UUID: Int] = [:]
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
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    func didRegister(token: Data) {
        lastError = nil
        let hex = Self.hex(token)
        Task { await registerWithRelay(token: hex) }
    }

    // MARK: Relay

    /// The push relay (relay/ in the repo). Builds signed by someone else can point at their own
    /// with the `bergr.push.relay` default.
    nonisolated static var relayURL: URL {
        UserDefaults.standard.string(forKey: "bergr.push.relay").flatMap(URL.init(string:))
            ?? URL(string: "https://bergr-relay.bergr.workers.dev")!
    }

    #if DEBUG
    nonisolated static let sandbox = true
    #else
    nonisolated static let sandbox = false
    #endif

    private static let secretKey = "bergr.push.secret"

    /// Registers this token with the relay once and keeps the secret it hands out; machines get
    /// only that secret, never the token or a signing key.
    private func registerWithRelay(token: String) async {
        // Turned off and on again quickly: the removal goes first, or it would remove this one.
        await unregistering?.value
        let saved = UserDefaults.standard.dictionary(forKey: Self.secretKey) as? [String: String]
        if saved?["token"] == token, saved?["relay"] == Self.relayURL.absoluteString, saved?["secret"] != nil {
            deviceToken = token
            return
        }
        var request = URLRequest(url: Self.relayURL.appending(path: "v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token, "bundle_id": Bundle.main.bundleIdentifier ?? "", "sandbox": Self.sandbox])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (response as? HTTPURLResponse)?.statusCode == 200, let secret = object?["secret"] as? String else {
                lastError = "The push relay refused this device: \(object?["error"] as? String ?? "no answer")"
                return
            }
            UserDefaults.standard.set(
                ["token": token, "secret": secret, "relay": Self.relayURL.absoluteString], forKey: Self.secretKey)
            deviceToken = token
        } catch {
            lastError = "Couldn't reach the push relay: \(error.localizedDescription)"
        }
    }

    /// The relay secret for the current token.
    var relaySecret: String? {
        let saved = UserDefaults.standard.dictionary(forKey: Self.secretKey) as? [String: String]
        return saved?["token"] == deviceToken ? saved?["secret"] : nil
    }

    /// Tells the relay to forget this device (204 or 401 both mean it's gone), then drops the
    /// stored secret so turning push on again registers fresh.
    private func unregisterFromRelay() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.secretKey) as? [String: String],
              let secret = saved["secret"] else { return }
        let relay = saved["relay"].flatMap(URL.init(string:)) ?? Self.relayURL
        // Forgotten now, not when the relay answers: turning push back on registers fresh.
        UserDefaults.standard.removeObject(forKey: Self.secretKey)
        unregistering = Task {
            var request = URLRequest(url: relay.appending(path: "v1/register"))
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                if status != 204 && status != 401 {
                    lastError = "The push relay didn't confirm removing this device (status \(status ?? 0))."
                }
            } catch {
                lastError = "Couldn't reach the push relay to remove this device: \(error.localizedDescription)"
            }
        }
    }

    private var unregistering: Task<Void, Never>?

    func didFail(_ error: Error) { lastError = error.localizedDescription }

    // MARK: Saving on machines

    /// Starts following the sessions: saves (or removes) this device on each machine once it connects.
    func run(sessions: SessionStore) {
        guard Delivery.helperSupported, !started else { return }
        started = true
        self.sessions = sessions
        if enabled { register() }
        observe()
    }

    private func observe() {
        let current = withObservationTracking {
            (enabled, deviceToken, alerts, (sessions?.ids ?? []).compactMap { id in
                sessions?.existing(id).map { ($0, $0.state == .connected && $0.canRunCommands) }
            })
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard let token = current.1 else { return }
        let alerts = current.2
        let state = "\(token)|\(current.0)|\(alerts)"
        for (session, ready) in current.3 where ready {
            let id = session.host.id
            let identity = ObjectIdentifier(session)
            if let last = written[id], last.session == identity, last.state == state { continue }
            // Removing needs no secret (the payload only uses the device id), so it still works
            // after the relay secret was forgotten.
            guard let secret = relaySecret ?? (current.0 ? nil : "") else { continue }
            written[id] = (identity, state)
            let command = Self.command(token: token, secret: secret, enabled: current.0, alerts: alerts, host: id)
            let enabled = current.0
            Task { @MainActor [weak self] in
                if enabled, let reason = await Self.probe(session) {
                    self?.helperState[id] = .unsupported(reason)
                    return
                }
                if await Self.run(command, on: session) == false {
                    if self?.written[id]?.state == state { self?.written[id] = nil }
                    if enabled { self?.helperState[id] = .failed("couldn't save this phone on the machine (is python3 there?)") }
                    return
                }
                if enabled { await self?.checkHelper(on: session) } else { await self?.removeHelper(on: session) }
            }
        }
    }

    // MARK: Support probe

    /// Why a machine can't run the helper, from `uname -s` and whether python3 exists.
    nonisolated static func unsupportedReason(uname: String?, hasPython: Bool) -> String? {
        let windows = "Windows isn't supported yet"
        guard let uname = uname?.trimmingCharacters(in: .whitespacesAndNewlines), !uname.isEmpty else { return windows }
        if ["MINGW", "MSYS", "CYGWIN", "Windows"].contains(where: { uname.localizedCaseInsensitiveContains($0) }) { return windows }
        return hasPython ? nil : "python3 isn't installed"
    }

    private nonisolated static let probeCommand = "uname -s 2>/dev/null; if command -v python3 >/dev/null 2>&1; then echo __python3__; fi"

    /// Splits the probe's output into (uname, hasPython). A first line that isn't a single word
    /// (a cmd.exe "not recognized" message, say) counts as no uname.
    nonisolated static func parseProbe(_ output: String) -> (uname: String?, hasPython: Bool) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let hasPython = lines.contains("__python3__")
        let first = lines.first { $0 != "__python3__" && !$0.isEmpty }
        return (first.flatMap { $0.contains(" ") ? nil : $0 }, hasPython)
    }

    /// The reason this machine can't run the helper; nil when it can, or when the probe itself failed.
    private static func probe(_ session: HostSession) async -> String? {
        guard let out = try? await outputOrError(probeCommand, on: session) else { return nil }
        let parsed = parseProbe(out)
        return unsupportedReason(uname: parsed.uname, hasPython: parsed.hasPython)
    }

    private static func run(_ command: String, on session: HostSession) async -> Bool {
        await output(command, on: session)?.contains("ok") ?? false
    }

    private static func output(_ command: String, on session: HostSession) async -> String? {
        try? await outputOrError(command, on: session)
    }

    /// The command's output; gives up after 20 seconds so a stuck channel can't hang a check.
    private static func outputOrError(_ command: String, on session: HostSession) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let pipe = try await session.openExec(command)
                defer { pipe.close() }
                var out = Data()
                do {
                    for try await chunk in pipe.output { out.append(chunk) }
                } catch {
                    // Citadel can report the channel as already closed after the command has
                    // answered and exited (NIO ChannelError.alreadyClosed, seen with Citadel
                    // 0.12); the answer is complete, so keep it.
                    if out.isEmpty { throw error }
                }
                return String(decoding: out, as: UTF8.self)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw HelperError("no answer after 20 seconds")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    struct HelperError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
        try? await helperResultOrError(op, script: script, on: session)
    }

    private static func helperResultOrError(_ op: String, script: String? = nil, on session: HostSession) async throws -> [String: Any] {
        guard let installer else { throw HelperError("the installer is missing from the app") }
        let command = installerCommand(installer: installer, op: op, script: script)
        let out = try await outputOrError(command, on: session)
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw HelperError(line.isEmpty ? "no answer from the machine" : "unexpected answer: \(line.prefix(120))")
        }
        return object
    }

    /// Asks once (per machine) to install or update the helper when it is missing or older than the bundled one.
    func checkHelper(on session: HostSession) async {
        let id = session.host.id
        guard let bundled = Self.bundledVersion else {
            helperState[id] = .failed("the helper is missing from the app")
            return
        }
        helperState[id] = .checking
        if let reason = await Self.probe(session) {
            helperState[id] = .unsupported(reason)
            return
        }
        let status: [String: Any]
        do {
            status = try await Self.helperResultOrError("status", on: session)
        } catch {
            helperState[id] = .failed(error.localizedDescription)
            return
        }
        let installed = status["installed"] as? Bool ?? false
        let version = status["version"] as? Int
        helperVersion[id] = installed ? version : nil
        if installed, let version, version >= bundled {
            helperState[id] = .current
            return
        }
        helperState[id] = installed ? .outdated : .missing
        guard enabled, !Self.declinedHosts().contains(id.uuidString) else { return }
        installQueue.enqueue(PendingInstall(session: session, hostName: session.host.name, isUpdate: installed))
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
            helperVersion[id] = Self.bundledVersion
            let updated = before == .outdated
            // A real alert from the machine, through the whole chain, proves it works.
            let sent = await Self.output("python3 -I ~/.local/bin/bergr-notify --test 2>&1", on: session)
            let tested = sent?.contains("sent 1") == true || sent?.contains("sent 2") == true
            finishedMessage = (updated ? "The push helper on \(name) is updated." : "Push alerts are set up on \(name).")
                + (tested ? " A test alert is on its way." : " The test alert didn't go out; check Settings → When Bergr isn't open.")
        } else {
            helperState[id] = before
            let reason = result?["error"] as? String ?? "no answer from the machine"
            lastError = "Couldn't install the push helper on \(name): \(reason)"
        }
    }

    func decline(_ pending: PendingInstall) {
        Self.setDeclined(true, host: pending.session.host.id)
        installQueue.pop()
    }

    /// The user agreed: next in the queue, and the install runs.
    func accept(_ pending: PendingInstall) {
        installQueue.pop()
        Task { await install(on: pending.session) }
    }

    /// Settings' Install button: clears an earlier "Not now" and installs right away.
    func installFromSettings(on session: HostSession) {
        Self.setDeclined(false, host: session.host.id)
        installQueue.remove(session.host.id)
        Task { await install(on: session) }
    }

    // MARK: Command

    /// A stable id for this device on machines, so the token itself never has to be stored there.
    nonisolated static func deviceID(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What goes in the payload for this device: the relay and its secret, not the APNs token.
    nonisolated static func payload(token: String, secret: String, enabled: Bool, alerts: Bool = true,
                                    relay: URL = relayURL, name: String, key: Data? = PushAlertKey.current(),
                                    host: UUID? = nil) -> Data {
        var device: [String: Any] = ["id": deviceID(token: token), "relay": relay.absoluteString,
                                     "secret": secret, "name": name]
        // Bergr's id for this machine, sent back with each alert so a tap opens this machine.
        if let host { device["host_id"] = host.uuidString }
        if let key { device["key"] = key.base64EncodedString() }
        // Off: the helper keeps the Live Activity current but sends no notifications (v10 on).
        if !alerts { device["alerts"] = false }
        let object: [String: Any] = ["op": enabled ? "add" : "remove", "device": device]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Script and payload both travel base64-encoded, so no shell quoting can break them.
    static func command(token: String, secret: String, enabled: Bool, alerts: Bool = true, host: UUID? = nil) -> String {
        command(payload: payload(token: token, secret: secret, enabled: enabled, alerts: alerts,
                                 name: DeviceName.current, host: host))
    }

    nonisolated static func command(payload: Data) -> String {
        "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' "
            + Data(mergeScript.utf8).base64EncodedString() + " " + payload.base64EncodedString()
    }

    /// Read-modify-write of push.json: adds or removes one device by id (entries a machine-held
    /// key sends to directly carry a token instead and are left alone).
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
    dev = p["device"]
    devs = c.get("devices")
    devs = [x for x in devs if isinstance(x, dict)] if isinstance(devs, list) else []
    rest = [x for x in devs if x.get("id") != dev["id"]]
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
        // Helpers from version 6 send Bergr's own id for the machine.
        if let id = UUID(uuidString: hostname), sessions.existing(id) != nil { return (id, address) }
        let matches = sessions.ids.compactMap { sessions.existing($0) }
            .filter { $0.terminals.contains { $0.address == address } }
        let best = matches.first { $0.host.name.caseInsensitiveCompare(hostname) == .orderedSame }
            ?? matches.first { $0.state == .connected } ?? matches.first
        return best.map { ($0.host.id, address) }
    }
}

/// The install prompt and the "finished" notice. Attached to both RootView and SettingsView, so
/// a prompt isn't lost behind Settings: only the one matching where the user is shows it.
struct PushPrompts: ViewModifier {
    let inSettings: Bool
    @State private var push = PushRegistration.shared

    private var active: Bool { push.settingsOpen == inSettings }

    func body(content: Content) -> some View {
        content
            .alert(
                push.pendingInstall.map {
                    $0.isUpdate ? "Update the push helper on \($0.hostName)?" : "Install the push helper on \($0.hostName)?"
                } ?? "",
                isPresented: Binding(get: { active && push.pendingInstall != nil }, set: { _ in }),
                presenting: push.pendingInstall
            ) { pending in
                Button(pending.isUpdate ? "Update" : "Install") { push.accept(pending) }
                Button("Not now", role: .cancel) { push.decline(pending) }
            } message: { _ in
                Text("It watches your agents with herdr-core and sends an alert when one needs you. It installs to ~/.local/bin/bergr-notify and runs as a user service. Nothing runs as root.")
            }
            .alert(
                push.finishedMessage ?? "",
                isPresented: Binding(
                    get: { active && push.finishedMessage != nil && push.pendingInstall == nil },
                    set: { if !$0 { push.finishedMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            }
    }
}
