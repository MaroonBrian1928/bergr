#if os(macOS)
import Foundation
import Testing
@testable import SSHTransport

@Test func systemSSHUsesAgentWithoutPromptsOrPTY() throws {
    let args = try SystemSSH.arguments(
        target: SSHTarget(host: "example.test", username: "tester"), command: "herdr-core connect")
    #expect(args.contains("BatchMode=yes"))
    #expect(args.contains("StrictHostKeyChecking=yes"))
    #expect(args.contains("-T"))
    #expect(Array(args.suffix(4)) == ["tester", "--", "example.test", "herdr-core connect"])
    #expect(!args.contains("-i"))
}

@Test func systemSSHRejectsOptionInjection() {
    #expect(throws: SSHTransportError.self) {
        try SystemSSH.arguments(target: SSHTarget(host: "-oProxyCommand=bad", username: "me"), command: "whoami")
    }
}

@Test func systemSSHForwardUsesTheSameOptionsWithoutACommand() throws {
    let args = try SystemSSH.forwardArguments(
        target: SSHTarget(host: "example.test", username: "tester"), localPort: 61000, remotePort: 3000)
    #expect(args.first == "-N")
    #expect(!args.contains("-T"))
    #expect(args.contains("BatchMode=yes"))
    #expect(args.contains("ExitOnForwardFailure=yes"))
    #expect(args.contains("127.0.0.1:61000:localhost:3000"))
    #expect(Array(args.suffix(2)) == ["--", "example.test"])
    #expect(try SystemSSH.freeLocalPort() > 0)
}

@Test func closedSystemSSHDoesNotLaunchCommands() async {
    let ssh = SSHConnection.system(to: SSHTarget(host: "unused", username: "me"))
    await ssh.close()
    #expect(!ssh.isConnected)
    await #expect(throws: (any Error).self) { try await ssh.openExec("whoami") }
}
#endif
