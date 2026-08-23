import AppKit
import SwiftUI

/// Keeps the standard macOS window controls while letting the split-view
/// surfaces visually continue through the title-bar area.
struct MacWindowChromeConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenAttached(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenAttached(nsView)
    }

    private func configureWhenAttached(_ view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.title = title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentMinSize = NSSize(width: 1_040, height: 680)

            // NavigationSplitView updates its own empty navigation title later
            // in the same pass. Restore the meaningful, visually hidden window
            // title for Window menu entries and accessibility.
            DispatchQueue.main.async {
                window.title = title
                window.titleVisibility = .hidden
            }
        }
    }
}
