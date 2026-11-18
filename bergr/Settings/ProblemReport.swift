import SwiftUI
#if os(iOS)
import MessageUI
import UIKit
#endif

/// A problem report from Diagnostics: what went wrong, the app and device, and the log. Sent by
/// email (the whole log attached) or as a GitHub issue (the end of the log in the issue, the whole
/// log copied to paste in). Nothing is sent by the app itself: the user sends it, and sees it first.
nonisolated enum ProblemReport {
    static let email = "support@bergr.dev"
    static let repo = "MaroonBrian1928/bergr"
    /// Lines of the log that go into the issue itself (a URL holds only so much).
    static let issueLines = 40
    static let issueURLLimit = 7000

    static func environment(version: String, system: String, device: String) -> String {
        "Bergr \(version) · \(system) · \(device)"
    }

    static func subject(_ description: String) -> String {
        let first = description.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Problem report" : String(first.prefix(80))
    }

    static func body(description: String, environment: String, log: [String]) -> String {
        """
        \(description.isEmpty ? "(No description)" : description)

        \(environment)

        Log:
        \(log.joined(separator: "\n"))
        """
    }

    /// GitHub's new-issue page filled in: the description, the environment and the last lines of
    /// the log, kept under the length a URL can carry.
    static func issueURL(description: String, environment: String, log: [String]) -> URL? {
        var tail = Array(log.suffix(issueLines))
        while true {
            let body = """
            \(description.isEmpty ? "(No description)" : description)

            \(environment)

            <details><summary>Log (last \(tail.count) lines; the whole log is on the clipboard, paste it below)</summary>

            ```
            \(tail.joined(separator: "\n"))
            ```
            </details>
            """
            var c = URLComponents(string: "https://github.com/\(repo)/issues/new")!
            c.queryItems = [URLQueryItem(name: "title", value: subject(description)),
                            URLQueryItem(name: "body", value: body)]
            if let url = c.url, url.absoluteString.count <= issueURLLimit || tail.isEmpty { return url }
            tail.removeFirst(max(1, tail.count / 4))
        }
    }
}

/// What the report form is doing; owned by the screen, so its sheet and alert hang off the list
/// itself (attached to a row inside a List, a sheet closed again at once).
@Observable final class ProblemReportForm {
    var description = ""
    var mailing = false
    var warningPublic = false
}

extension ProblemReportForm {
    static var environment: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        #if os(iOS)
        let system = "iOS \(UIDevice.current.systemVersion)"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let device = "Mac"
        #endif
        return ProblemReport.environment(version: version, system: system, device: device)
    }

    func sendEmail(lines: [String], openURL: OpenURLAction) {
        #if os(iOS)
        if MFMailComposeViewController.canSendMail() { mailing = true; return }
        #endif
        let body = ProblemReport.body(description: description, environment: Self.environment, log: lines)
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = ProblemReport.email
        c.queryItems = [URLQueryItem(name: "subject", value: ProblemReport.subject(description)),
                        URLQueryItem(name: "body", value: body)]
        if let url = c.url { openURL(url) }
    }

    func openIssue(lines: [String], openURL: OpenURLAction) {
        Pasteboard.copy(lines.joined(separator: "\n"))
        if let url = ProblemReport.issueURL(description: description, environment: Self.environment, log: lines) {
            openURL(url)
        }
    }
}

/// "Report a Problem" in Diagnostics: the rows. The sheet and alert: `problemReportPresentation`.
struct ProblemReportSection: View {
    @Bindable var form: ProblemReportForm
    let lines: [String]
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            TextField("What went wrong?", text: $form.description, axis: .vertical)
                .lineLimit(3...8)
            Button("Send by Email", systemImage: "envelope") { form.sendEmail(lines: lines, openURL: openURL) }
            Button("Open a GitHub Issue", systemImage: "exclamationmark.bubble") { form.warningPublic = true }
            Label {
                Text("GitHub issues are **public**. Anyone on the internet can read the log you post there: machine names, folders, file names and bits of messages. Email is private.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        } header: {
            Text("Report a Problem")
        } footer: {
            Text("Includes the log below, the app version and the device type. For GitHub, the whole log is copied for you to paste in.")
        }
    }
}

private struct ProblemReportPresentation: ViewModifier {
    @Bindable var form: ProblemReportForm
    let lines: [String]
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert("This will be public", isPresented: $form.warningPublic) {
                Button("Send by Email Instead") { form.sendEmail(lines: lines, openURL: openURL) }
                Button("Open Public Issue", role: .destructive) { form.openIssue(lines: lines, openURL: openURL) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Anyone on the internet can read a GitHub issue, including the log: machine names, folders, file names and bits of your agents' messages. Check it and remove anything private before you post. Email goes only to the developer.")
            }
            #if os(iOS)
            .sheet(isPresented: $form.mailing) {
                MailComposer(subject: ProblemReport.subject(form.description),
                             body: form.description + "\n\n" + ProblemReportForm.environment,
                             attachment: ProblemReport.body(description: form.description,
                                                            environment: ProblemReportForm.environment, log: lines),
                             onDone: { form.mailing = false })
                    .ignoresSafeArea()
            }
            #endif
    }
}

extension View {
    func problemReportPresentation(_ form: ProblemReportForm, lines: [String]) -> some View {
        modifier(ProblemReportPresentation(form: form, lines: lines))
    }
}

#if os(iOS)
/// Mail's compose sheet, with the report attached as diagnostics.txt.
private struct MailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let attachment: String
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([ProblemReport.email])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.addAttachmentData(Data(attachment.utf8), mimeType: "text/plain", fileName: "diagnostics.txt")
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onDone()
        }
    }
}
#endif
