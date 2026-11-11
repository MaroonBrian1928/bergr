import HerdrKit
import SwiftUI

/// Asks whether to trust a machine's host key the first time Bergr connects to it, whichever
/// screen started the connection (the Agents screen connects every machine at once).
struct TrustPrompt: ViewModifier {
    let sessions: SessionStore
    func body(content: Content) -> some View {
        let session = sessions.awaitingTrust
        content.alert(
            "Trust \(session?.host.name ?? "this machine")?",
            isPresented: .constant(session?.pendingHostKey != nil),
            presenting: session?.pendingHostKey
        ) { _ in
            Button("Trust") { session?.answerHostKey(trust: true) }
            Button("Don't Trust", role: .cancel) { session?.answerHostKey(trust: false) }
        } message: { key in
            Text("This is the first time Bergr connects to \(key.host). Its fingerprint is\n\n\(key.fingerprint)\n\n"
                + "To check it, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on that machine.")
        }
    }
}
