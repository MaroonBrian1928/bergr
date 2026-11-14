import HerdrKit
import SwiftUI
import TerminalCore
import WebKit

/// A page an agent serves on its machine (`localhost:3000`), shown here through the SSH connection.
struct LocalPreviewSheet: View {
    let address: LocalWebAddress
    let session: HostSession?
    @Environment(\.dismiss) private var dismiss
    @State private var page = LocalPreviewPage()

    private var machine: String { session?.host.name ?? "the machine" }

    var body: some View {
        NavigationStack {
            Group {
                switch page.phase {
                case .connecting:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView("Couldn't open the page", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                case .showing:
                    WebViewHost(webView: page.webView)
                }
            }
            .navigationTitle(page.shownAddress ?? address.display)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .automatic) {
                    Button("Back", systemImage: "chevron.backward") { page.webView.goBack() }
                        .disabled(!page.canGoBack)
                    Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                    #if os(macOS)
                    if page.isLocal {
                        // Only this Mac's own localhost is the agent's: a browser can't reach a tunnel's page.
                        Link(destination: page.currentURL ?? address.url) {
                            Label("Open in browser", systemImage: "safari")
                        }
                    }
                    #endif
                }
            }
        }
        .task { await page.open(address, session: session, machine: machine) }
        .onDisappear { page.close() }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 600)
        #endif
    }
}

@Observable
final class LocalPreviewPage: NSObject, WKNavigationDelegate {
    enum Phase: Equatable { case connecting, showing, failed(String) }

    private(set) var phase = Phase.connecting
    private(set) var canGoBack = false
    /// The page shown, as the agent's address (`localhost:3000/path`).
    private(set) var shownAddress: String?
    private(set) var currentURL: URL?
    private(set) var isLocal = false
    @ObservationIgnored let webView = WKWebView()
    @ObservationIgnored private var forward: PortForward?
    @ObservationIgnored private var address: LocalWebAddress?
    @ObservationIgnored private var localPort = 0
    @ObservationIgnored private var machine = ""
    @ObservationIgnored private var closed = false

    func open(_ address: LocalWebAddress, session: HostSession?, machine: String) async {
        self.address = address
        self.machine = machine
        webView.navigationDelegate = self
        do {
            guard let session else { throw SessionError.connectionLost }
            let forward = try await session.forwardPort(address.port)
            guard !closed else { forward?.close(); return }
            self.forward = forward
            isLocal = forward == nil
            localPort = forward?.localPort ?? address.port
            phase = .showing
            webView.load(URLRequest(url: address.forwarded(to: localPort)))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reload() {
        guard let address, localPort != 0 else { return }
        phase = .showing
        if webView.url == nil { webView.load(URLRequest(url: address.forwarded(to: localPort))) } else { webView.reload() }
    }

    func close() {
        closed = true
        webView.stopLoading()
        forward?.close()
        forward = nil
    }

    private func update() {
        canGoBack = webView.canGoBack
        guard let url = webView.url else { return }
        if let shown = LocalWebAddress(url: url), shown.port == localPort, let address {
            var original = shown
            original.port = address.port
            shownAddress = original.display
            currentURL = original.url
        } else {
            shownAddress = url.absoluteString
            currentURL = url
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail(error) }

    private func fail(_ error: any Error) {
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        phase = .failed(Self.message(for: error, port: address?.port ?? 0, machine: machine))
    }

    /// The forward accepts the connection and drops it when nothing listens on the machine's port.
    static func message(for error: NSError, port: Int, machine: String) -> String {
        let refused = [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                       NSURLErrorBadServerResponse, NSURLErrorZeroByteResource]
        if error.domain == NSURLErrorDomain, refused.contains(error.code) {
            return "Nothing is listening on port \(port) on \(machine)."
        }
        return error.localizedDescription
    }
}

#if os(iOS)
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
