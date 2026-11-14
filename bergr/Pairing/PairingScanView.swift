#if os(iOS)
import AVFoundation
import KeyStore
import SwiftUI

/// "Scan from Mac": reads the Mac's pairing code, adds its machines and sends this phone's public
/// key back so the Mac can let it in.
struct PairingScanView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case scanning
        case working
        case done(added: Int, total: Int)
        case failed(String)
    }

    @State private var phase = Phase.scanning

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .scanning:
                    VStack(spacing: 16) {
                        QRScanner { code in Task { await handle(code) } }
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Text("On your Mac, open Bergr Settings, Machines & Keys, then Pair iPhone.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                case .working:
                    ProgressView("Sending your key to the Mac…")
                case .done(let added, let total):
                    ContentUnavailableView {
                        Label("Paired", systemImage: "checkmark.circle")
                    } description: {
                        Text("Added \(added) of \(total) machines. Confirm on your Mac to let this phone in.")
                    } actions: {
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't pair", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Scan again") { phase = .scanning }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Scan from Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func handle(_ code: String) async {
        guard phase == .scanning else { return }
        phase = .working
        do {
            let payload = try PairingPayload.decode(code)
            guard let key = keys.keys.last ?? keys.generate(label: "Bergr", requireBiometry: false) else {
                throw PairingError.invalid(keys.unavailableReason ?? "no key")
            }
            let added = hosts.importPaired(payload.hosts, keyID: key.id)
            try await PairingClient.send(line: key.authorizedKeysLine, payload: payload)
            phase = .done(added: added, total: payload.hosts.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The camera, reporting each QR code it sees.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: (String) -> Void = { _ in }
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            let session = session
            Task.detached { session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let session = session
            Task.detached { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            MainActor.assumeIsolated { found(code) }
        }
    }
}
#endif
