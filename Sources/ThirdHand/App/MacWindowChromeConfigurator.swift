import AppKit
import SwiftUI

/// Keeps the standard macOS window controls while letting the split-view
/// surfaces visually continue through the title-bar area.
@MainActor
struct MacWindowChromeConfigurator: NSViewRepresentable {
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title)
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        context.coordinator.title = title
        if let window = nsView.window {
            context.coordinator.configure(window)
        }
    }

    @MainActor
    final class Coordinator {
        var title: String

        init(title: String) {
            self.title = title
        }

        func configure(_ window: NSWindow) {
            if !MacWindowChromeConfigurator.configuredWindows.contains(window) {
                MacWindowChromeConfigurator.configuredWindows.add(window)

                // These properties participate in SwiftUI's window-drag graph.
                // Set them only when attaching to a new window; repeating the
                // mutation during a root-view replacement can crash AttributeGraph.
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.isMovableByWindowBackground = true
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
                window.contentMinSize = NSSize(width: 1_040, height: 680)
            }

            if window.title != title {
                window.title = title
            }
            window.titleVisibility = .hidden
        }
    }

    @MainActor
    final class WindowAttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            coordinator?.configure(window)
        }
    }
}
