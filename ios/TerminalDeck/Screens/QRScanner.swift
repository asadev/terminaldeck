/**
 * The camera half of pairing.
 *
 * A pairing code is 200-odd characters of base64url and nobody is typing that.
 * The Mac shows a QR; this reads it. Everything else about pairing — what the
 * code means, whether it is valid — belongs to `PairingCodeParser`; this hands
 * over a string and stops.
 *
 * ## Three states, all of which happen
 *
 *  - **No camera.** The Simulator has none, and neither does a phone with the
 *    camera disabled by a profile. `AVCaptureDevice.default` returns nil and the
 *    view says so rather than showing a black rectangle that never resolves.
 *  - **Not asked yet.** iOS will not open a camera without permission, and the
 *    prompt only appears when something asks. So this asks on appear.
 *  - **Refused.** The one state where the app has to send someone to Settings,
 *    because nothing it does can re-ask.
 *
 * In all three the paste field above is still there, which is why none of them
 * are dead ends.
 */

import AVFoundation
import SwiftUI
import UIKit

struct QRScanner: View {
    /// Fires once per distinct code. The parent decides what to do with it.
    let onCode: (String) -> Void

    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        Group {
            if !hasCamera {
                message("No camera on this device.", "Paste the pairing link instead.")
            } else {
                switch access {
                case .authorized:
                    CameraPreview(onCode: onCode)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
                case .denied, .restricted:
                    message("Camera access is off.",
                            "Turn it on in Settings › \(Brand.name), or paste the link instead.")
                default:
                    message("Camera not started.", "Allow access to scan the QR code on the Mac.")
                }
            }
        }
        .frame(height: 220)
        .task {
            guard hasCamera, access == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted ? .authorized : .denied
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(Theme.faint)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The capture session, in the smallest UIKit view that can hold one.
private struct CameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.onCode = onCode
        view.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onCode = onCode
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.stop()
    }
}

final class PreviewView: UIView, @unchecked Sendable {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var layerAdded = false
    /// One code, once. A QR in frame is decoded every frame, and pairing twice
    /// with the same single-use token is a refusal the user did not cause.
    private var delivered: String?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func start() {
        guard !layerAdded else { return }
        layerAdded = true
        preview.session = session
        preview.videoGravity = .resizeAspectFill

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(Coordinator(view: self), queue: .main)
        // Set after the output is attached: the available types are empty until
        // then, and assigning an unavailable type raises.
        output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { $0 == .qr }

        // Starting a capture session blocks for long enough to drop frames on
        // the main thread, and iOS logs a warning about it.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    fileprivate func found(_ code: String) {
        guard delivered != code else { return }
        delivered = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(code)
    }

    private final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        // Strong: the delegate is not retained by the output, and the view owns
        // the session that owns the output, so this cannot outlive the view.
        private let view: PreviewView

        init(view: PreviewView) {
            self.view = view
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            for object in objects {
                guard let readable = object as? AVMetadataMachineReadableCodeObject,
                      readable.type == .qr,
                      let value = readable.stringValue else { continue }
                view.found(value)
                return
            }
        }
    }
}
