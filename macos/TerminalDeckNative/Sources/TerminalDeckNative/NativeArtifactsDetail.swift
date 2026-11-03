import AppKit
import Quartz
import SwiftUI
import TerminalDeckNativeCore

/// Quick Look preview used by the Artifacts preview sheet (item 104).
struct ArtifactsQuickLook: NSViewRepresentable {
    let url: URL
    /// The file's modified time: when it moves, the preview is drawn again.
    let revision: Double

    final class Coordinator {
        var url: URL?
        var revision: Double = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = false
        show(in: view, context: context)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        show(in: view, context: context)
    }

    private func show(in view: QLPreviewView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.url != url {
            coordinator.url = url
            coordinator.revision = revision
            view.previewItem = url as NSURL
        } else if coordinator.revision != revision {
            coordinator.revision = revision
            view.refreshPreviewItem()
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

// MARK: - A page's markup

