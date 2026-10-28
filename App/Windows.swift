import AppKit
import SwiftUI

/// Finds the window hosting this view: the MenuBarExtra panel, the Settings window.
struct HostingWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context _: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = { found in DispatchQueue.main.async { window = found } }
        return probe
    }

    func updateNSView(_: Probe, context _: Context) {}
}

/// Keeps a window's vertical centre where it is when its height changes: Settings grows and shrinks around its middle
/// as the panes change, instead of hanging from its top edge and running down the screen. A move by
/// the user sets a new centre.
@MainActor
final class KeepsVerticalCentre {
    private var midY: CGFloat = 0
    private var size: CGSize = .zero
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        midY = window.frame.midY
        size = window.frame.size
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let window {
                        self?.changed(window)
                    }
                }
            }
        }
    }

    private func changed(_ window: NSWindow) {
        guard window.frame.size == size else {
            // A new height: the system kept the top edge; put the middle back.
            size = window.frame.size
            var origin = window.frame.origin
            origin.y = midY - size.height / 2
            if let screen = window.screen?.visibleFrame {
                origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            }
            window.setFrameOrigin(origin)
            return
        }
        midY = window.frame.midY // moved, not resized
    }
}
