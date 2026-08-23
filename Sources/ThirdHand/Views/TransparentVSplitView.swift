import AppKit
import SwiftUI

struct TransparentVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    let top: Top
    let bottom: Bottom
    let minimumTopHeight: CGFloat
    let minimumBottomHeight: CGFloat
    let idealBottomHeight: CGFloat
    let maximumBottomHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            minimumTopHeight: minimumTopHeight,
            minimumBottomHeight: minimumBottomHeight,
            idealBottomHeight: idealBottomHeight,
            maximumBottomHeight: maximumBottomHeight
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = InvisibleDividerSplitView(frame: .zero)
        splitView.isVertical = false
        splitView.delegate = context.coordinator

        let coordinator = context.coordinator
        splitView.onLayout = { [weak coordinator] splitView in
            coordinator?.applyInitialPosition(to: splitView)
        }

        let topHostingView = NSHostingView(rootView: top)
        let bottomHostingView = NSHostingView(rootView: bottom)
        splitView.addArrangedSubview(topHostingView)
        splitView.addArrangedSubview(bottomHostingView)

        splitView.setHoldingPriority(.init(240), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 1)

        context.coordinator.bottomHostingView = bottomHostingView
        context.coordinator.topHostingView = topHostingView

        DispatchQueue.main.async { [weak splitView] in
            guard let splitView else { return }
            coordinator.applyInitialPosition(to: splitView)
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.topHostingView?.rootView = top
        context.coordinator.bottomHostingView?.rootView = bottom
        context.coordinator.updateLimits(
            minimumTopHeight: minimumTopHeight,
            minimumBottomHeight: minimumBottomHeight,
            idealBottomHeight: idealBottomHeight,
            maximumBottomHeight: maximumBottomHeight
        )

        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak splitView] in
            guard let splitView else { return }
            coordinator.applyInitialPosition(to: splitView)
        }
    }

    static func dismantleNSView(_ splitView: NSSplitView, coordinator: Coordinator) {
        (splitView as? InvisibleDividerSplitView)?.onLayout = nil
        splitView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var topHostingView: NSHostingView<Top>?
        var bottomHostingView: NSHostingView<Bottom>?

        private var minimumTopHeight: CGFloat
        private var minimumBottomHeight: CGFloat
        private var idealBottomHeight: CGFloat
        private var maximumBottomHeight: CGFloat
        private var didApplyInitialPosition = false

        init(
            minimumTopHeight: CGFloat,
            minimumBottomHeight: CGFloat,
            idealBottomHeight: CGFloat,
            maximumBottomHeight: CGFloat
        ) {
            self.minimumTopHeight = minimumTopHeight
            self.minimumBottomHeight = minimumBottomHeight
            self.idealBottomHeight = idealBottomHeight
            self.maximumBottomHeight = maximumBottomHeight
        }

        func updateLimits(
            minimumTopHeight: CGFloat,
            minimumBottomHeight: CGFloat,
            idealBottomHeight: CGFloat,
            maximumBottomHeight: CGFloat
        ) {
            self.minimumTopHeight = minimumTopHeight
            self.minimumBottomHeight = minimumBottomHeight
            self.idealBottomHeight = idealBottomHeight
            self.maximumBottomHeight = maximumBottomHeight
        }

        func applyInitialPosition(to splitView: NSSplitView) {
            guard !didApplyInitialPosition,
                  splitView.bounds.height >= minimumTopHeight + minimumBottomHeight
            else {
                return
            }

            // A detail view can be created while a sheet is still closing, when
            // the split view temporarily has no usable height. Mark the position
            // before changing frames so the resulting layout pass cannot recurse.
            didApplyInitialPosition = true
            splitView.adjustSubviews()
            splitView.setPosition(
                clampedDividerPosition(
                    splitView.bounds.height - idealBottomHeight,
                    in: splitView
                ),
                ofDividerAt: 0
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(
                proposedMinimumPosition,
                max(minimumTopHeight, splitView.bounds.height - maximumBottomHeight)
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(
                proposedMaximumPosition,
                splitView.bounds.height - minimumBottomHeight
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            clampedDividerPosition(proposedPosition, in: splitView)
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            view !== bottomHostingView
        }

        func splitView(
            _ splitView: NSSplitView,
            additionalEffectiveRectOfDividerAt dividerIndex: Int
        ) -> NSRect {
            guard let topPane = splitView.arrangedSubviews.first else { return .zero }
            return NSRect(
                x: splitView.bounds.minX,
                y: topPane.frame.maxY - 4,
                width: splitView.bounds.width,
                height: 8
            )
        }

        private func clampedDividerPosition(_ proposedPosition: CGFloat, in splitView: NSSplitView) -> CGFloat {
            let lowerBound = max(minimumTopHeight, splitView.bounds.height - maximumBottomHeight)
            let upperBound = max(lowerBound, splitView.bounds.height - minimumBottomHeight)
            return min(max(proposedPosition, lowerBound), upperBound)
        }
    }
}

private final class InvisibleDividerSplitView: NSSplitView {
    var onLayout: ((NSSplitView) -> Void)?

    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }

    override func layout() {
        super.layout()
        onLayout?(self)
    }

    override func drawDivider(in rect: NSRect) {}
}
