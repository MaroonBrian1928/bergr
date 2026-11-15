import Foundation
import Testing
@testable import bergr

struct PushRegistrationTests {
    @Test func tokenIsLowercaseHex() {
        #expect(PushRegistration.hex(Data([0x00, 0xAB, 0x0F, 0xFF])) == "00ab0fff")
    }

    @Test func payloadCarriesRelaySecretNotToken() throws {
        let relay = URL(string: "https://relay.example")!
        let data = PushRegistration.payload(token: "ab12", secret: "s3cret", enabled: true, relay: relay, name: "Phone")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["op"] as? String == "add")
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["token"] == nil)
        #expect(device["secret"] as? String == "s3cret")
        #expect(device["relay"] as? String == "https://relay.example")
        #expect(device["id"] as? String == PushRegistration.deviceID(token: "ab12"))
        #expect(device["name"] as? String == "Phone")
        let removed = PushRegistration.payload(token: "ab12", secret: "s3cret", enabled: false, relay: relay, name: "Phone")
        #expect((try JSONSerialization.jsonObject(with: removed) as? [String: Any])?["op"] as? String == "remove")
    }

    @Test func payloadCarriesHostID() throws {
        let host = UUID()
        let data = PushRegistration.payload(token: "ab12", secret: "s", enabled: true, name: "Phone", key: nil, host: host)
        let device = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["device"] as? [String: Any])
        #expect(device["host_id"] as? String == host.uuidString)
    }

    @Test func deviceIDIsStableAndHidesToken() {
        #expect(PushRegistration.deviceID(token: "ab12") == PushRegistration.deviceID(token: "ab12"))
        #expect(PushRegistration.deviceID(token: "ab12").count == 16)
        #expect(PushRegistration.deviceID(token: "ab12") != PushRegistration.deviceID(token: "ab13"))
    }

    @Test func commandEncodesScriptAndPayload() throws {
        let payload = Data("{\"x\":1}".utf8)
        let parts = PushRegistration.command(payload: payload).command.split(separator: " ")
        #expect(parts.prefix(3) == ["python3", "-I", "-c"])
        let args = parts.suffix(2)
        let script = try #require(Data(base64Encoded: String(args.first!)))
        #expect(String(decoding: script, as: UTF8.self) == PushRegistration.mergeScript)
        #expect(Data(base64Encoded: String(args.last!)) == payload)
    }

    @MainActor @Test func parsesVersionLine() {
        #expect(PushRegistration.version(in: "import os\nVERSION = 7\nx = 1") == 7)
        #expect(PushRegistration.version(in: "# VERSION = 3\n") == nil)
        #expect((PushRegistration.bundledVersion ?? 0) >= 1)
    }

    @Test func declineSetRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "PushRegistrationTests.\(UUID())"))
        let a = UUID(), b = UUID()
        #expect(PushRegistration.declinedHosts(defaults).isEmpty)
        PushRegistration.setDeclined(true, host: a, defaults: defaults)
        PushRegistration.setDeclined(true, host: b, defaults: defaults)
        #expect(PushRegistration.declinedHosts(defaults) == [a.uuidString, b.uuidString])
        PushRegistration.setDeclined(false, host: a, defaults: defaults)
        #expect(PushRegistration.declinedHosts(defaults) == [b.uuidString])
    }

    @Test func installerCommandCarriesInstallerAndArgs() throws {
        let parts = PushRegistration.installerCommand(installer: "print(1)", op: "install", script: "VERSION = 1")
            .command.split(separator: " ")
        #expect(parts.prefix(3) == ["python3", "-I", "-c"])
        #expect(String(decoding: try #require(Data(base64Encoded: String(parts[parts.count - 2]))), as: UTF8.self) == "print(1)")
        let args = try #require(Data(base64Encoded: String(parts.last!)))
        let object = try #require(try JSONSerialization.jsonObject(with: args) as? [String: String])
        #expect(object == ["op": "install", "script": "VERSION = 1"])
    }

    @Test func payloadIncludesKeyOnlyWhenGiven() throws {
        let relay = URL(string: "https://relay.example")!
        let key = Data(repeating: 7, count: 64)
        func device(_ key: Data?) throws -> [String: Any] {
            let data = PushRegistration.payload(token: "ab12", secret: "s", enabled: true, relay: relay, name: "P", key: key)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(object["device"] as? [String: Any])
        }
        #expect(try device(key)["key"] as? String == key.base64EncodedString())
        #expect(try device(nil)["key"] == nil)
    }

    @Test func unsupportedReasons() {
        let windows = "Windows isn't supported yet"
        #expect(PushRegistration.unsupportedReason(uname: "Linux", hasPython: true) == nil)
        #expect(PushRegistration.unsupportedReason(uname: "Darwin", hasPython: true) == nil)
        #expect(PushRegistration.unsupportedReason(uname: nil, hasPython: true) == windows)
        #expect(PushRegistration.unsupportedReason(uname: "MINGW64_NT-10.0", hasPython: true) == windows)
        #expect(PushRegistration.unsupportedReason(uname: "Linux", hasPython: false) == "python3 isn't installed")
        let parsed = PushRegistration.parseProbe("Linux\n__python3__\n")
        #expect(parsed.uname == "Linux" && parsed.hasPython)
        #expect(PushRegistration.parseProbe("'uname' is not recognized as a command").uname == nil)
    }

    @Test func windowsProbeAndTestCommands() {
        let py = #"cmd /d /v:on /s /c "set PATH=%LOCALAPPDATA%\Programs\Python\Python313;%PATH%&& set P=python.exe& where /q py.exe&& set P=py.exe -3& !P! "#
        #expect(PushRegistration.probeCommand(windows: true) == .init(command: py + #"-V 2>&1""#))
        #expect(PushRegistration.testCommand(windows: true)
            == .init(command: py + #"-I %LOCALAPPDATA%\bergr\bergr-notify.py --test 2>&1""#))
        #expect(PushRegistration.testCommand(windows: false).command == "python3 -I ~/.local/bin/bergr-notify --test 2>&1")
        #expect(PushRegistration.autoApprovalsCommand(windows: true).command
            == #"cmd /d /s /c "type %USERPROFILE%\.config\bergr\auto-approvals.json 2>nul""#)
        #expect(PushRegistration.windowsUnsupportedReason("Python 3.13.16\r\n") == nil)
        #expect(PushRegistration.windowsUnsupportedReason("'python.exe' is not recognized") == "Python 3 isn't installed")
    }

    /// Windows: the code goes on stdin (cmd lines stop at 8191 characters); the line is short and
    /// free of `$` and inner quotes so PowerShell and cmd pass it alike.
    @Test func windowsRegisterAndInstallSendCodeOnStdin() throws {
        let payload = Data("{\"x\":1}".utf8)
        let register = PushRegistration.command(payload: payload, windows: true)
        let stage1 = #"-I -c S=__import__('sys');exec(S.stdin.buffer.readline())""#
        #expect(register.command == PushRegistration.windowsPython + stage1)
        let line = String(decoding: try #require(register.input), as: UTF8.self)
        #expect(line == "import base64,sys;sys.argv=['-c','\(payload.base64EncodedString())'];exec(base64.b64decode('"
            + Data(PushRegistration.mergeScript.utf8).base64EncodedString() + "'))\n")
        let script = String(repeating: "x = 1\n", count: 20_000) + "VERSION = 22\n"
        let install = PushRegistration.installerCommand(installer: "print(1)", op: "install", script: script, windows: true)
        #expect(install.command.count < 8191 && !install.command.contains("$"))
        #expect(install.command == PushRegistration.windowsPython + stage1)
        #expect(String(decoding: try #require(install.input), as: UTF8.self).contains(Data("print(1)".utf8).base64EncodedString()))
        #expect(PushRegistration.command(payload: payload).input == nil)
    }

    @Test func installQueueIsFIFOAndDedupes() {
        struct Item: Identifiable { let id: UUID; let tag: Int }
        let a = UUID(), b = UUID()
        var queue = PushRegistration.InstallQueue<Item>()
        let first = queue.enqueue(Item(id: a, tag: 1))
        let second = queue.enqueue(Item(id: b, tag: 2))
        let dup = queue.enqueue(Item(id: a, tag: 3))
        #expect(first && second && !dup)
        let p1 = queue.pop()
        #expect(p1?.tag == 1)
        #expect(queue.first?.tag == 2)
        let p2 = queue.pop()
        let p3 = queue.pop()
        #expect(p2?.tag == 2)
        #expect(p3 == nil)
    }
}

struct SentImagesTests {
    @Test func splitsPathsFromWords() {
        let path = "/tmp/bergr-images/8056fc8c-109a-483a-b686-ba1283a89934.jpg"
        let parts = SentImages.split("\(path) Test")
        #expect(parts.paths == [path])
        #expect(parts.text == "Test")
        #expect(SentImages.split("\(path) \(path)").text.isEmpty)
        #expect(SentImages.split("no images here").paths.isEmpty)
        #expect(SentImages.split("/tmp/bergr-images/x.jpg").paths.isEmpty)
    }
}
