import AppKit
import SwiftUI

struct InlineComposerToken: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var utf16Offset: Int

    init(id: UUID = UUID(), text: String, utf16Offset: Int) {
        self.id = id
        self.text = text
        self.utf16Offset = utf16Offset
    }
}

enum InlineComposerContent {
    static func resolvedText(
        text: String,
        tokens: [InlineComposerToken]
    ) -> String {
        let result = NSMutableString(string: text)
        let orderedTokens = tokens.enumerated().sorted { lhs, rhs in
            let lhsOffset = clampedOffset(lhs.element.utf16Offset, in: text)
            let rhsOffset = clampedOffset(rhs.element.utf16Offset, in: text)
            if lhsOffset == rhsOffset {
                return lhs.offset > rhs.offset
            }
            return lhsOffset > rhsOffset
        }

        for entry in orderedTokens {
            let offset = clampedOffset(entry.element.utf16Offset, in: text)
            result.insert(
                insertionText(
                    for: entry.element.text,
                    in: result,
                    at: offset
                ),
                at: offset
            )
        }

        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nearestWordBoundary(to proposedOffset: Int, in text: String) -> Int {
        let clamped = clampedOffset(proposedOffset, in: text)
        let boundaries = wordBoundaryOffsets(in: text)
        var nearest = boundaries.first ?? 0
        var nearestDistance = abs(nearest - clamped)

        for boundary in boundaries.dropFirst() {
            let distance = abs(boundary - clamped)
            if distance < nearestDistance
                || (distance == nearestDistance && boundary > nearest) {
                nearest = boundary
                nearestDistance = distance
            }
        }

        return nearest
    }

    static func wordBoundaryOffsets(in text: String) -> [Int] {
        let string = text as NSString
        var offsets: Set<Int> = [0, string.length]

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            let utf16Range = NSRange(range, in: text)
            offsets.insert(utf16Range.location)
            offsets.insert(NSMaxRange(utf16Range))
        }

        if string.length > 0 {
            var previousWasWhitespace = isWhitespace(string.character(at: 0))
            for offset in 1..<string.length {
                let isCurrentWhitespace = isWhitespace(string.character(at: offset))
                if isCurrentWhitespace != previousWasWhitespace {
                    offsets.insert(offset)
                }
                previousWasWhitespace = isCurrentWhitespace
            }
        }

        return offsets.sorted()
    }

    static func insertionText(
        for tokenText: String,
        in text: NSString,
        at proposedOffset: Int
    ) -> String {
        let offset = min(max(0, proposedOffset), text.length)
        let needsLeadingSpace = offset > 0
            && !isWhitespace(text.character(at: offset - 1))
        let needsTrailingSpace = offset < text.length
            && !isWhitespace(text.character(at: offset))

        return (needsLeadingSpace ? " " : "")
            + tokenText
            + (needsTrailingSpace ? " " : "")
    }

    static func clampedOffset(_ offset: Int, in text: String) -> Int {
        min(max(0, offset), (text as NSString).length)
    }

    static func replacingToken(
        _ tokenID: UUID,
        with text: String,
        in tokens: [InlineComposerToken]
    ) -> [InlineComposerToken] {
        tokens.map { token in
            guard token.id == tokenID else { return token }
            var replacement = token
            replacement.text = text
            return replacement
        }
    }

    static func movingToken(
        _ tokenID: UUID,
        to proposedOffset: Int,
        in text: String,
        tokens: [InlineComposerToken]
    ) -> [InlineComposerToken] {
        guard let tokenIndex = tokens.firstIndex(where: { $0.id == tokenID }) else {
            return tokens
        }

        let targetOffset = nearestWordBoundary(
            to: proposedOffset,
            in: text
        )
        guard tokens[tokenIndex].utf16Offset != targetOffset else {
            return tokens
        }

        var updatedTokens = tokens
        updatedTokens[tokenIndex].utf16Offset = targetOffset
        return updatedTokens
    }

    static func insertingToken(
        text tokenText: String,
        replacing proposedRange: NSRange,
        in text: String,
        tokens: [InlineComposerToken],
        id: UUID = UUID()
    ) -> (text: String, tokens: [InlineComposerToken], tokenID: UUID) {
        let source = text as NSString
        let location = min(max(0, proposedRange.location), source.length)
        let length = min(
            max(0, proposedRange.length),
            source.length - location
        )
        let replacementRange = NSRange(location: location, length: length)
        let replacementEnd = NSMaxRange(replacementRange)
        let updatedText = NSMutableString(string: source)
        updatedText.deleteCharacters(in: replacementRange)

        var updatedTokens = tokens.map { token in
            var token = token
            if replacementRange.length > 0 {
                if token.utf16Offset >= replacementEnd {
                    token.utf16Offset -= replacementRange.length
                } else if token.utf16Offset > replacementRange.location {
                    token.utf16Offset = replacementRange.location
                }
            }
            token.utf16Offset = min(
                max(0, token.utf16Offset),
                updatedText.length
            )
            return token
        }
        updatedTokens.append(
            InlineComposerToken(
                id: id,
                text: tokenText,
                utf16Offset: replacementRange.location
            )
        )
        return (String(updatedText), updatedTokens, id)
    }

    static func tokenAttachmentRange(
        in attributedString: NSAttributedString,
        inside attributedRange: NSRange
    ) -> NSRange? {
        guard attributedRange.location >= 0,
              NSMaxRange(attributedRange) <= attributedString.length
        else {
            return nil
        }

        let source = attributedString.string as NSString
        for location in attributedRange.location..<NSMaxRange(attributedRange) {
            guard source.character(at: location) == 0xFFFC,
                  attributedString.attribute(
                    .attachment,
                    at: location,
                    effectiveRange: nil
                  ) is NSTextAttachment
            else {
                continue
            }
            return NSRange(location: location, length: 1)
        }
        return nil
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(
            UnicodeScalar(character) ?? UnicodeScalar(0)
        )
    }
}

struct InlineTokenComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var tokens: [InlineComposerToken]

    let placeholder: String
    let isEnabled: Bool
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    let onRecognizeCommand: (ChatSlashCommandDescriptor, NSRange) -> UUID
    let onSubmit: () -> Void
    let onMoveSuggestion: (Int) -> Bool
    let onActivateToken: (UUID) -> Void
    let onDismissCommandPalette: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> InlineTokenComposerScrollView {
        let scrollView = InlineTokenComposerScrollView()
        let textView = scrollView.composerTextView
        textView.delegate = context.coordinator
        textView.inputHandler = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.applyState(to: textView, force: true)
        return scrollView
    }

    func updateNSView(
        _ scrollView: InlineTokenComposerScrollView,
        context: Context
    ) {
        context.coordinator.parent = self
        let textView = scrollView.composerTextView
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        context.coordinator.applyState(to: textView)
        scrollView.refreshMeasuredHeight()

        if isFocused,
           textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder !== textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: InlineTokenComposerScrollView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? max(nsView.bounds.width, 160)
        return CGSize(
            width: width,
            height: nsView.measuredHeight(for: width)
        )
    }

    @MainActor
    final class Coordinator: NSObject,
        NSTextViewDelegate,
        InlineTokenComposerInputHandling {

        var parent: InlineTokenComposerField
        weak var textView: InlineTokenComposerTextView?

        private var isApplyingState = false
        private var commandRecognitionTask: Swift.Task<Void, Never>?

        init(parent: InlineTokenComposerField) {
            self.parent = parent
        }

        func applyState(
            to textView: InlineTokenComposerTextView,
            force: Bool = false,
            selectingTokenID: UUID? = nil
        ) {
            let current = snapshot(from: textView)
            let desiredTokens = normalizedTokens(parent.tokens, in: parent.text)
            guard force
                || current.text != parent.text
                || current.tokens != desiredTokens
            else {
                configure(textView, plainTextIsEmpty: current.text.isEmpty)
                return
            }

            let previousSelection = textView.selectedRange()
            let attributedText = makeAttributedText(
                text: parent.text,
                tokens: desiredTokens,
                appearance: textView.effectiveAppearance
            )

            isApplyingState = true
            textView.textStorage?.setAttributedString(attributedText)
            textView.typingAttributes = plainTextAttributes

            if let selectingTokenID,
               let tokenRange = tokenRange(selectingTokenID, in: textView) {
                textView.setSelectedRange(
                    NSRange(location: NSMaxRange(tokenRange), length: 0)
                )
            } else {
                textView.setSelectedRange(
                    NSRange(
                        location: min(previousSelection.location, attributedText.length),
                        length: 0
                    )
                )
            }
            isApplyingState = false

            configure(textView, plainTextIsEmpty: parent.text.isEmpty)
            textView.didChangeTextLayout()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingState,
                  let textView = notification.object as? InlineTokenComposerTextView
            else {
                return
            }

            let current = snapshot(from: textView)
            if parent.text != current.text {
                parent.text = current.text
            }
            if parent.tokens != current.tokens {
                parent.tokens = current.tokens
            }

            parent.onDismissCommandPalette()
            configure(textView, plainTextIsEmpty: current.text.isEmpty)
            textView.typingAttributes = plainTextAttributes
            textView.didChangeTextLayout()
            scheduleCommandRecognition(for: current, in: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = plainTextAttributes
        }

        func composerTextView(
            _ textView: InlineTokenComposerTextView,
            dropsToken tokenID: UUID,
            to point: NSPoint
        ) -> Bool {
            guard parent.tokens.contains(where: { $0.id == tokenID }) else {
                return false
            }

            let current = snapshot(from: textView)
            let attributedOffset = textView.characterOffset(at: point)
            let tokensBeforeOffset = current.tokens.filter { token in
                guard let range = tokenRange(token.id, in: textView) else { return false }
                return range.location < attributedOffset
            }.count
            let plainOffset = max(0, attributedOffset - tokensBeforeOffset)
            let updatedTokens = InlineComposerContent.movingToken(
                tokenID,
                to: plainOffset,
                in: current.text,
                tokens: parent.tokens
            )
            guard updatedTokens != parent.tokens else {
                return true
            }

            parent.tokens = updatedTokens
            applyState(
                to: textView,
                force: true,
                selectingTokenID: tokenID
            )
            return true
        }

        func composerTextViewDidRequestSubmit(_ textView: InlineTokenComposerTextView) {
            parent.onSubmit()
        }

        func composerTextView(
            _ textView: InlineTokenComposerTextView,
            didRequestSuggestionMove offset: Int
        ) -> Bool {
            parent.onMoveSuggestion(offset)
        }

        func composerTextView(
            _ textView: InlineTokenComposerTextView,
            activatesToken tokenID: UUID
        ) {
            parent.onActivateToken(tokenID)
        }

        func composerTextViewDidInteractWithPlainText(
            _ textView: InlineTokenComposerTextView
        ) {
            parent.onDismissCommandPalette()
        }

        func composerTextView(
            _ textView: InlineTokenComposerTextView,
            unwrapsTokenIn direction: InlineTokenDeletionDirection
        ) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }

            let tokenLocation: Int
            switch direction {
            case .backward:
                guard selection.location > 0 else { return false }
                tokenLocation = selection.location - 1
            case .forward:
                tokenLocation = selection.location
            }

            guard let tokenID = tokenID(at: tokenLocation, in: textView),
                  let tokenText = tokenText(at: tokenLocation, in: textView),
                  let storage = textView.textStorage
            else {
                return false
            }

            let source = storage.string as NSString
            let sourceWithoutToken = NSMutableString(string: source)
            sourceWithoutToken.deleteCharacters(
                in: NSRange(location: tokenLocation, length: 1)
            )
            let replacement = InlineComposerContent.insertionText(
                for: tokenText,
                in: sourceWithoutToken,
                at: tokenLocation
            )
            guard textView.shouldChangeText(
                in: NSRange(location: tokenLocation, length: 1),
                replacementString: replacement
            ) else {
                return true
            }

            let hasLeadingSpace = replacement.hasPrefix(" ")
            let caretLocation = tokenLocation
                + (hasLeadingSpace ? 1 : 0)
                + (tokenText as NSString).length

            isApplyingState = true
            storage.replaceCharacters(
                in: NSRange(location: tokenLocation, length: 1),
                with: NSAttributedString(
                    string: replacement,
                    attributes: plainTextAttributes
                )
            )
            textView.setSelectedRange(NSRange(location: caretLocation, length: 0))
            isApplyingState = false
            textView.didChangeText()

            let current = snapshot(from: textView)
            parent.text = current.text
            parent.tokens = current.tokens.filter { $0.id != tokenID }
            configure(textView, plainTextIsEmpty: current.text.isEmpty)
            textView.didChangeTextLayout()
            return true
        }

        private var plainTextAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        }

        private func scheduleCommandRecognition(
            for snapshot: (text: String, tokens: [InlineComposerToken]),
            in textView: InlineTokenComposerTextView
        ) {
            commandRecognitionTask?.cancel()
            guard ChatSlashCommandDescriptor.recognizedCompletion(
                    in: snapshot.text
                  ) != nil
            else {
                return
            }

            commandRecognitionTask = Swift.Task { @MainActor [weak self, weak textView] in
                await Swift.Task.yield()
                guard !Swift.Task.isCancelled,
                      let self,
                      let textView
                else {
                    return
                }

                let latest = self.snapshot(from: textView)
                guard let completion = ChatSlashCommandDescriptor.recognizedCompletion(
                        in: latest.text
                      )
                else {
                    return
                }

                let tokenID = self.parent.onRecognizeCommand(
                    completion.command,
                    completion.replacementRange
                )
                self.applyState(
                    to: textView,
                    force: true,
                    selectingTokenID: tokenID
                )
            }
        }

        private func configure(
            _ textView: InlineTokenComposerTextView,
            plainTextIsEmpty: Bool
        ) {
            textView.placeholder = parent.placeholder
            textView.plainTextIsEmpty = plainTextIsEmpty
            textView.setAccessibilityPlaceholderValue(parent.placeholder)
            textView.needsDisplay = true
        }

        private func normalizedTokens(
            _ tokens: [InlineComposerToken],
            in text: String
        ) -> [InlineComposerToken] {
            tokens.map { token in
                var token = token
                token.utf16Offset = InlineComposerContent.clampedOffset(
                    token.utf16Offset,
                    in: text
                )
                return token
            }
        }

        private func makeAttributedText(
            text: String,
            tokens: [InlineComposerToken],
            appearance: NSAppearance
        ) -> NSAttributedString {
            let result = NSMutableAttributedString(
                string: text,
                attributes: plainTextAttributes
            )
            var insertedTokenCount = 0

            for token in tokens.enumerated().sorted(by: { lhs, rhs in
                if lhs.element.utf16Offset == rhs.element.utf16Offset {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.utf16Offset < rhs.element.utf16Offset
            }).map(\.element) {
                let attachment = NSTextAttachment(data: nil, ofType: nil)
                let image = tokenImage(for: token.text, appearance: appearance)
                attachment.image = image
                attachment.bounds = CGRect(
                    x: 0,
                    y: -6,
                    width: image.size.width,
                    height: image.size.height
                )
                attachment.lineLayoutPadding = 3
                image.accessibilityDescription = "Команда \(token.text)"

                let tokenString = NSMutableAttributedString(
                    string: "\u{FFFC}",
                    attributes: plainTextAttributes
                )
                tokenString.addAttributes(
                    [
                        .attachment: attachment,
                        .thirdHandInlineComposerTokenID: token.id.uuidString,
                        .thirdHandInlineComposerTokenText: token.text,
                        .toolTip: "Перетащите между словами"
                    ],
                    range: NSRange(location: 0, length: 1)
                )

                let insertionOffset = min(
                    max(0, token.utf16Offset + insertedTokenCount),
                    result.length
                )
                result.insert(tokenString, at: insertionOffset)
                insertedTokenCount += 1
            }

            return result
        }

        private func snapshot(
            from textView: NSTextView
        ) -> (text: String, tokens: [InlineComposerToken]) {
            guard let storage = textView.textStorage else {
                return (textView.string, [])
            }

            var tokens: [(range: NSRange, token: InlineComposerToken)] = []
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(
                .thirdHandInlineComposerTokenID,
                in: fullRange
            ) { value, range, _ in
                guard let idString = value as? String,
                      let id = UUID(uuidString: idString),
                      let attachmentRange = InlineComposerContent.tokenAttachmentRange(
                        in: storage,
                        inside: range
                      ),
                      let tokenText = storage.attribute(
                        .thirdHandInlineComposerTokenText,
                        at: attachmentRange.location,
                        effectiveRange: nil
                      ) as? String
                else {
                    return
                }
                tokens.append((
                    attachmentRange,
                    InlineComposerToken(
                        id: id,
                        text: tokenText,
                        utf16Offset: 0
                    )
                ))
            }

            let plainText = NSMutableString(string: storage.string)
            for entry in tokens.sorted(by: { $0.range.location > $1.range.location }) {
                plainText.deleteCharacters(in: entry.range)
            }

            let resolvedTokens = tokens.enumerated().map { index, entry in
                var token = entry.token
                token.utf16Offset = entry.range.location - index
                return token
            }
            return (String(plainText), resolvedTokens)
        }

        private func tokenID(
            at characterIndex: Int,
            in textView: NSTextView
        ) -> UUID? {
            guard let storage = textView.textStorage,
                  characterIndex >= 0,
                  characterIndex < storage.length,
                  InlineComposerContent.tokenAttachmentRange(
                    in: storage,
                    inside: NSRange(location: characterIndex, length: 1)
                  ) != nil,
                  let idString = storage.attribute(
                    .thirdHandInlineComposerTokenID,
                    at: characterIndex,
                    effectiveRange: nil
                  ) as? String
            else {
                return nil
            }
            return UUID(uuidString: idString)
        }

        private func tokenText(
            at characterIndex: Int,
            in textView: NSTextView
        ) -> String? {
            guard let storage = textView.textStorage,
                  characterIndex >= 0,
                  characterIndex < storage.length,
                  InlineComposerContent.tokenAttachmentRange(
                    in: storage,
                    inside: NSRange(location: characterIndex, length: 1)
                  ) != nil
            else {
                return nil
            }
            return storage.attribute(
                .thirdHandInlineComposerTokenText,
                at: characterIndex,
                effectiveRange: nil
            ) as? String
        }

        private func tokenRange(
            _ tokenID: UUID,
            in textView: NSTextView
        ) -> NSRange? {
            guard let storage = textView.textStorage else { return nil }
            var result: NSRange?
            storage.enumerateAttribute(
                .thirdHandInlineComposerTokenID,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard value as? String == tokenID.uuidString,
                      let attachmentRange = InlineComposerContent.tokenAttachmentRange(
                        in: storage,
                        inside: range
                      )
                else {
                    return
                }
                result = attachmentRange
                stop.pointee = true
            }
            return result
        }

        private func tokenImage(
            for text: String,
            appearance: NSAppearance
        ) -> NSImage {
            let font = NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize - 1,
                weight: .medium
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let imageSize = NSSize(
                width: ceil(textSize.width) + 16,
                height: 24
            )

            return NSImage(size: imageSize, flipped: false) { rect in
                appearance.performAsCurrentDrawingAppearance {
                    NSColor.secondaryLabelColor
                        .withAlphaComponent(0.14)
                        .setFill()
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: 7,
                        yRadius: 7
                    ).fill()

                    let textOrigin = NSPoint(
                        x: 8,
                        y: floor((rect.height - textSize.height) / 2)
                    )
                    (text as NSString).draw(
                        at: textOrigin,
                        withAttributes: attributes
                    )
                }
                return true
            }
        }
    }
}

enum InlineTokenDeletionDirection {
    case backward
    case forward
}

@MainActor
protocol InlineTokenComposerInputHandling: AnyObject {
    func composerTextViewDidRequestSubmit(_ textView: InlineTokenComposerTextView)
    func composerTextViewDidInteractWithPlainText(
        _ textView: InlineTokenComposerTextView
    )
    func composerTextView(
        _ textView: InlineTokenComposerTextView,
        didRequestSuggestionMove offset: Int
    ) -> Bool
    func composerTextView(
        _ textView: InlineTokenComposerTextView,
        activatesToken tokenID: UUID
    )
    func composerTextView(
        _ textView: InlineTokenComposerTextView,
        unwrapsTokenIn direction: InlineTokenDeletionDirection
    ) -> Bool
    func composerTextView(
        _ textView: InlineTokenComposerTextView,
        dropsToken tokenID: UUID,
        to point: NSPoint
    ) -> Bool
}

@MainActor
final class InlineTokenComposerScrollView: NSScrollView {
    let composerTextView = InlineTokenComposerTextView()

    private let minimumEditorHeight: CGFloat = 24
    private let maximumEditorHeight: CGFloat = 128

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none

        composerTextView.drawsBackground = false
        composerTextView.backgroundColor = .clear
        composerTextView.isRichText = true
        composerTextView.importsGraphics = false
        composerTextView.allowsUndo = true
        composerTextView.isHorizontallyResizable = false
        composerTextView.isVerticallyResizable = true
        composerTextView.autoresizingMask = [.width]
        composerTextView.textContainerInset = .zero
        composerTextView.textContainer?.lineFragmentPadding = 0
        composerTextView.textContainer?.widthTracksTextView = true
        composerTextView.textContainer?.heightTracksTextView = false
        composerTextView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        composerTextView.textColor = .labelColor
        composerTextView.isAutomaticQuoteSubstitutionEnabled = false
        composerTextView.isAutomaticDashSubstitutionEnabled = false
        composerTextView.isAutomaticTextReplacementEnabled = false
        composerTextView.isAutomaticSpellingCorrectionEnabled = false
        documentView = composerTextView
        composerTextView.registerForDraggedTypes(
            composerTextView.acceptableDragTypes
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        let contentWidth = max(1, width - contentInsets.left - contentInsets.right)
        composerTextView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: .greatestFiniteMagnitude
        )
        composerTextView.layoutManager?.ensureLayout(
            for: composerTextView.textContainer!
        )
        let usedHeight = composerTextView.layoutManager?
            .usedRect(for: composerTextView.textContainer!)
            .height ?? minimumEditorHeight
        return min(
            maximumEditorHeight,
            max(minimumEditorHeight, ceil(usedHeight) + 2)
        )
    }

    func refreshMeasuredHeight() {
        let height = measuredHeight(for: max(bounds.width, 160))
        hasVerticalScroller = height >= maximumEditorHeight
        composerTextView.frame.size = NSSize(
            width: max(contentSize.width, 1),
            height: max(height, contentSize.height)
        )
        invalidateIntrinsicContentSize()
    }
}

@MainActor
final class InlineTokenComposerTextView: NSTextView {
    weak var inputHandler: (any InlineTokenComposerInputHandling)?

    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    var plainTextIsEmpty = true {
        didSet { needsDisplay = true }
    }

    private var pendingTokenDrag: (
        tokenID: UUID,
        characterIndex: Int,
        mouseDownPoint: NSPoint,
        rect: NSRect
    )?
    private var activeTokenDragSource: InlineTokenDragSource?
    private var tokenDragReturnSelection: NSRange?
    private var activeTokenDropTarget: (
        tokenID: UUID,
        plainTextOffset: Int,
        attributedOffset: Int,
        indicatorRect: NSRect
    )?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let inheritedTypes = super.acceptableDragTypes
        guard !inheritedTypes.contains(.thirdHandInlineComposerToken) else {
            return inheritedTypes
        }
        return inheritedTypes + [.thirdHandInlineComposerToken]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tokenHit = tokenHit(at: point) {
            pendingTokenDrag = (
                tokenID: tokenHit.tokenID,
                characterIndex: tokenHit.characterIndex,
                mouseDownPoint: point,
                rect: tokenHit.rect
            )
            window?.makeFirstResponder(self)
            let returnSelection = NSRange(
                location: tokenHit.characterIndex + 1,
                length: 0
            )
            setSelectedRange(returnSelection)
            tokenDragReturnSelection = returnSelection
            return
        }

        pendingTokenDrag = nil
        tokenDragReturnSelection = nil
        clearTokenDropTarget(restoreSelection: false)
        inputHandler?.composerTextViewDidInteractWithPlainText(self)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pendingTokenDrag else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let horizontalDistance = abs(point.x - pendingTokenDrag.mouseDownPoint.x)
        let verticalDistance = abs(point.y - pendingTokenDrag.mouseDownPoint.y)
        guard horizontalDistance >= 3 || verticalDistance >= 3 else { return }

        beginTokenDraggingSession(
            for: pendingTokenDrag,
            with: event
        )
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pendingTokenDrag {
            inputHandler?.composerTextView(
                self,
                activatesToken: pending.tokenID
            )
            pendingTokenDrag = nil
            tokenDragReturnSelection = nil
            return
        }
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for token in tokenGeometries() {
            addCursorRect(
                token.rect.insetBy(dx: -3, dy: -2),
                cursor: .openHand
            )
        }
    }

    override func draggingEntered(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard draggedTokenID(from: sender) != nil else {
            return super.draggingEntered(sender)
        }
        return updateTokenDropTarget(from: sender)
    }

    override func draggingUpdated(
        _ sender: NSDraggingInfo
    ) -> NSDragOperation {
        guard draggedTokenID(from: sender) != nil else {
            return super.draggingUpdated(sender)
        }
        return updateTokenDropTarget(from: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        let isTokenDrag = sender.flatMap { draggedTokenID(from: $0) } != nil
        guard isTokenDrag || activeTokenDropTarget != nil
        else {
            super.draggingExited(sender)
            return
        }
        clearTokenDropTarget(restoreSelection: true)
    }

    override func prepareForDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        guard draggedTokenID(from: sender) != nil else {
            return super.prepareForDragOperation(sender)
        }
        return true
    }

    override func performDragOperation(
        _ sender: NSDraggingInfo
    ) -> Bool {
        guard let tokenID = draggedTokenID(from: sender) else {
            return super.performDragOperation(sender)
        }

        _ = updateTokenDropTarget(from: sender)
        let point = convert(sender.draggingLocation, from: nil)
        let accepted = inputHandler?.composerTextView(
            self,
            dropsToken: tokenID,
            to: point
        ) == true
        clearTokenDropTarget(restoreSelection: !accepted)
        if accepted {
            tokenDragReturnSelection = nil
        }
        sender.animatesToDestination = accepted
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 36 where !modifiers.contains(.option) && !hasMarkedText(),
             76 where !modifiers.contains(.option) && !hasMarkedText():
            inputHandler?.composerTextViewDidRequestSubmit(self)
        case 125:
            if inputHandler?.composerTextView(
                self,
                didRequestSuggestionMove: 1
            ) != true {
                super.keyDown(with: event)
            }
        case 126:
            if inputHandler?.composerTextView(
                self,
                didRequestSuggestionMove: -1
            ) != true {
                super.keyDown(with: event)
            }
        case 51:
            if inputHandler?.composerTextView(
                self,
                unwrapsTokenIn: .backward
            ) != true {
                super.keyDown(with: event)
            }
        case 117:
            if inputHandler?.composerTextView(
                self,
                unwrapsTokenIn: .forward
            ) != true {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if plainTextIsEmpty, !placeholder.isEmpty {
            drawPlaceholder()
        }
        super.draw(dirtyRect)
        drawTokenDropIndicator(in: dirtyRect)
    }

    func didChangeTextLayout() {
        enclosingScrollView.map { scrollView in
            (scrollView as? InlineTokenComposerScrollView)?.refreshMeasuredHeight()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func characterOffset(at point: NSPoint) -> Int {
        guard let layoutManager,
              let textContainer,
              textStorage?.length ?? 0 > 0
        else {
            return 0
        }

        let textPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let usedRect = layoutManager.usedRect(for: textContainer)
        if textPoint.y >= usedRect.maxY {
            return textStorage?.length ?? 0
        }
        if textPoint.y <= usedRect.minY, textPoint.x <= usedRect.minX {
            return 0
        }

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: textPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            actualGlyphRange: nil
        )
        return fraction >= 0.5
            ? NSMaxRange(characterRange)
            : characterRange.location
    }

    private func tokenHit(
        at point: NSPoint
    ) -> (tokenID: UUID, characterIndex: Int, rect: NSRect)? {
        tokenGeometries().first { token in
            token.rect.insetBy(dx: -3, dy: -2).contains(point)
        }
    }

    private func tokenGeometries() -> [(
        tokenID: UUID,
        characterIndex: Int,
        rect: NSRect
    )] {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0
        else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        var geometries: [(
            tokenID: UUID,
            characterIndex: Int,
            rect: NSRect
        )] = []
        textStorage.enumerateAttribute(
            .thirdHandInlineComposerTokenID,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, _ in
            guard let tokenIDString = value as? String,
                  let tokenID = UUID(uuidString: tokenIDString),
                  let attachmentRange = InlineComposerContent.tokenAttachmentRange(
                    in: textStorage,
                    inside: range
                  )
            else {
                return
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: attachmentRange,
                actualCharacterRange: nil
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).offsetBy(
                dx: textContainerOrigin.x,
                dy: textContainerOrigin.y
            )
            geometries.append((
                tokenID,
                attachmentRange.location,
                glyphRect
            ))
        }
        return geometries
    }

    private func updateTokenDropTarget(
        from draggingInfo: NSDraggingInfo
    ) -> NSDragOperation {
        guard let tokenID = draggedTokenID(from: draggingInfo),
              updateTokenDropTarget(
                for: tokenID,
                at: convert(draggingInfo.draggingLocation, from: nil)
              )
        else {
            clearTokenDropTarget(restoreSelection: false)
            return []
        }
        return .move
    }

    @discardableResult
    private func updateTokenDropTarget(
        for tokenID: UUID,
        at point: NSPoint
    ) -> Bool {
        guard let target = tokenDropTarget(for: tokenID, at: point) else {
            clearTokenDropTarget(restoreSelection: false)
            return false
        }

        activeTokenDropTarget = (
            tokenID,
            target.plainTextOffset,
            target.attributedOffset,
            target.indicatorRect
        )
        setSelectedRange(
            NSRange(location: target.attributedOffset, length: 0)
        )
        needsDisplay = true
        displayIfNeeded()
        return true
    }

    private func tokenDropTarget(
        for tokenID: UUID,
        at point: NSPoint
    ) -> (
        plainTextOffset: Int,
        attributedOffset: Int,
        indicatorRect: NSRect
    )? {
        guard let textStorage else { return nil }
        let geometries = tokenGeometries().sorted {
            $0.characterIndex < $1.characterIndex
        }
        guard geometries.contains(where: { $0.tokenID == tokenID }) else {
            return nil
        }

        let plainText = NSMutableString(string: textStorage.string)
        for geometry in geometries.reversed() {
            plainText.deleteCharacters(
                in: NSRange(location: geometry.characterIndex, length: 1)
            )
        }

        let attributedOffset = characterOffset(at: point)
        let attachmentsBeforeOffset = geometries.filter {
            $0.characterIndex < attributedOffset
        }.count
        let proposedPlainTextOffset = min(
            max(0, attributedOffset - attachmentsBeforeOffset),
            plainText.length
        )
        let targetPlainTextOffset = InlineComposerContent.nearestWordBoundary(
            to: proposedPlainTextOffset,
            in: String(plainText)
        )

        let tokenPlainTextOffsets = geometries.enumerated().map { index, geometry in
            geometry.characterIndex - index
        }
        let targetAttributedOffset = min(
            targetPlainTextOffset
                + tokenPlainTextOffsets.filter { $0 < targetPlainTextOffset }.count,
            textStorage.length
        )
        guard let indicatorRect = tokenDropIndicatorRect(
            at: targetAttributedOffset,
            fallbackPoint: point
        ) else {
            return nil
        }

        return (
            targetPlainTextOffset,
            targetAttributedOffset,
            indicatorRect
        )
    }

    private func tokenDropIndicatorRect(
        at attributedOffset: Int,
        fallbackPoint: NSPoint
    ) -> NSRect? {
        let insertionRange = NSRange(
            location: min(max(0, attributedOffset), textStorage?.length ?? 0),
            length: 0
        )
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = firstRect(
            forCharacterRange: insertionRange,
            actualRange: &actualRange
        )

        if let window, !screenRect.isEmpty {
            let windowRect = window.convertFromScreen(screenRect)
            let localRect = convert(windowRect, from: nil)
            let height = min(28, max(18, localRect.height))
            return NSRect(
                x: floor(localRect.minX) - 1,
                y: floor(localRect.midY - height / 2),
                width: 2,
                height: ceil(height)
            )
        }

        let fontHeight = ceil(
            (font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
                .boundingRectForFont.height
        )
        return NSRect(
            x: floor(min(max(bounds.minX, fallbackPoint.x), bounds.maxX)) - 1,
            y: floor(textContainerOrigin.y),
            width: 2,
            height: max(18, fontHeight)
        )
    }

    private func clearTokenDropTarget(restoreSelection: Bool) {
        activeTokenDropTarget = nil
        if restoreSelection,
           let tokenDragReturnSelection {
            let length = textStorage?.length ?? 0
            setSelectedRange(
                NSRange(
                    location: min(tokenDragReturnSelection.location, length),
                    length: 0
                )
            )
        }
        needsDisplay = true
        displayIfNeeded()
    }

    private func drawTokenDropIndicator(in dirtyRect: NSRect) {
        guard let indicatorRect = activeTokenDropTarget?.indicatorRect,
              dirtyRect.intersects(indicatorRect)
        else {
            return
        }

        NSColor.controlAccentColor.setFill()
        NSBezierPath(
            roundedRect: indicatorRect,
            xRadius: 1,
            yRadius: 1
        ).fill()
    }

    private func beginTokenDraggingSession(
        for pending: (
            tokenID: UUID,
            characterIndex: Int,
            mouseDownPoint: NSPoint,
            rect: NSRect
        ),
        with event: NSEvent
    ) {
        guard let textStorage,
              pending.characterIndex < textStorage.length,
              let attachment = textStorage.attribute(
                .attachment,
                at: pending.characterIndex,
                effectiveRange: nil
              ) as? NSTextAttachment,
              let image = attachment.image
        else {
            pendingTokenDrag = nil
            tokenDragReturnSelection = nil
            return
        }

        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setString(
            pending.tokenID.uuidString,
            forType: .thirdHandInlineComposerToken
        ) else {
            pendingTokenDrag = nil
            tokenDragReturnSelection = nil
            return
        }

        let draggingItem = NSDraggingItem(
            pasteboardWriter: pasteboardItem
        )
        draggingItem.setDraggingFrame(
            pending.rect,
            contents: image
        )

        let source = InlineTokenDragSource(
            owner: self,
            tokenID: pending.tokenID
        )
        activeTokenDragSource = source
        pendingTokenDrag = nil
        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: source
        )
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func draggedTokenID(
        from draggingInfo: NSDraggingInfo
    ) -> UUID? {
        draggingInfo.draggingPasteboard
            .string(forType: .thirdHandInlineComposerToken)
            .flatMap(UUID.init(uuidString:))
    }

    fileprivate func tokenDraggingSessionMoved(
        tokenID: UUID,
        to screenPoint: NSPoint
    ) {
        guard let point = localPoint(fromScreenPoint: screenPoint),
              visibleRect.insetBy(dx: -4, dy: -6).contains(point)
        else {
            clearTokenDropTarget(restoreSelection: true)
            return
        }
        _ = updateTokenDropTarget(for: tokenID, at: point)
    }

    @discardableResult
    fileprivate func tokenDraggingSessionDidEnd(
        tokenID: UUID,
        at screenPoint: NSPoint,
        operation: NSDragOperation
    ) -> Bool {
        var accepted = operation.contains(.move)
        if !accepted,
           let point = localPoint(fromScreenPoint: screenPoint),
           visibleRect.insetBy(dx: -4, dy: -6).contains(point) {
            _ = updateTokenDropTarget(for: tokenID, at: point)
            accepted = inputHandler?.composerTextView(
                self,
                dropsToken: tokenID,
                to: point
            ) == true
        }

        clearTokenDropTarget(restoreSelection: !accepted)
        tokenDragReturnSelection = nil
        activeTokenDragSource = nil
        window?.invalidateCursorRects(for: self)
        return accepted
    }

    private func localPoint(fromScreenPoint screenPoint: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        return convert(
            window.convertPoint(fromScreen: screenPoint),
            from: nil
        )
    }

    private func drawPlaceholder() {
        guard let font = font ?? typingAttributes[.font] as? NSFont else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = placeholderOrigin(for: font)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func placeholderOrigin(for font: NSFont) -> NSPoint {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0
        else {
            return textContainerOrigin
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: textStorage.length),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return textContainerOrigin }

        let lastGlyph = NSMaxRange(glyphRange) - 1
        var lineRange = NSRange()
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: lastGlyph,
            effectiveRange: &lineRange
        )
        let usedRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        let fontHeight = font.boundingRectForFont.height
        return NSPoint(
            x: textContainerOrigin.x + usedRect.maxX + 2,
            y: textContainerOrigin.y
                + lineRect.minY
                + max(0, (lineRect.height - fontHeight) / 2)
        )
    }

}

@MainActor
private final class InlineTokenDragSource: NSObject, NSDraggingSource {
    private weak var owner: InlineTokenComposerTextView?
    private let tokenID: UUID

    init(owner: InlineTokenComposerTextView, tokenID: UUID) {
        self.owner = owner
        self.tokenID = tokenID
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        movedTo screenPoint: NSPoint
    ) {
        owner?.tokenDraggingSessionMoved(
            tokenID: tokenID,
            to: screenPoint
        )
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        let accepted = owner?.tokenDraggingSessionDidEnd(
            tokenID: tokenID,
            at: screenPoint,
            operation: operation
        ) == true
        if accepted, operation.isEmpty {
            session.animatesToStartingPositionsOnCancelOrFail = false
        }
    }
}

private extension NSAttributedString.Key {
    static let thirdHandInlineComposerTokenID = Self(
        "ThirdHandInlineComposerTokenID"
    )
    static let thirdHandInlineComposerTokenText = Self(
        "ThirdHandInlineComposerTokenText"
    )
}

private extension NSPasteboard.PasteboardType {
    static let thirdHandInlineComposerToken = Self(
        "com.thirdhand.inline-composer-token"
    )
}
