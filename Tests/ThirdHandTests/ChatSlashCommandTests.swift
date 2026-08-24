import AppKit
import XCTest
@testable import ThirdHand

final class ChatSlashCommandTests: XCTestCase {
    func testParserDistinguishesCommandsFromOrdinaryMessages() throws {
        XCTAssertNil(try ChatSlashCommandParser.parse("обычное сообщение"))
        XCTAssertEqual(try ChatSlashCommandParser.parse("/context"), .context)
        XCTAssertEqual(try ChatSlashCommandParser.parse("/compact"), .compact)
        XCTAssertEqual(try ChatSlashCommandParser.parse("/handoff"), .handoff)
        XCTAssertEqual(
            try ChatSlashCommandParser.parse("/model gpt-5.6-sol"),
            .model("gpt-5.6-sol")
        )
        XCTAssertEqual(
            try ChatSlashCommandParser.parse("/session resume abc-123"),
            .session(.resume("abc-123"))
        )
    }

    func testParserRejectsUnknownAndIncompleteSessionCommands() {
        XCTAssertThrowsError(try ChatSlashCommandParser.parse("/unknown"))
        XCTAssertThrowsError(try ChatSlashCommandParser.parse("/session resume"))
    }

    func testCommandsDeclareEveryAvailableFollowUpPalette() {
        let kinds = Dictionary(
            uniqueKeysWithValues: ChatSlashCommandDescriptor.all.map {
                ($0.name, $0.argumentKind)
            }
        )

        XCTAssertEqual(kinds["/model"], .model)
        XCTAssertEqual(kinds["/session"], .session)
        XCTAssertEqual(
            kinds["/help"],
            Optional.some(ChatSlashCommandArgumentKind.none)
        )
        XCTAssertEqual(
            kinds["/compact"],
            Optional.some(ChatSlashCommandArgumentKind.none)
        )
    }

    func testModelOptionsFillCompleteModelCommandAndMarkCurrentValue() throws {
        let options = ChatSlashCommandOption.modelOptions(
            [
                AgentValueOption(
                    "gpt-5.6-sol",
                    title: "5.6 Sol",
                    detail: "Быстрая"
                ),
                AgentValueOption(
                    "GPT-5.6-SOL",
                    title: "Дубликат"
                ),
                AgentValueOption(
                    "gpt-5.6-terra",
                    title: "5.6 Terra"
                )
            ],
            selectedID: "gpt-5.6-sol",
            sourceTitle: "Codex"
        )

        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].argumentText, "gpt-5.6-sol")
        XCTAssertEqual(options[0].commandText, "/model gpt-5.6-sol")
        XCTAssertTrue(options[0].isCurrent)
        XCTAssertTrue(options[0].detail.contains("Текущая модель"))
        XCTAssertEqual(
            try ChatSlashCommandParser.parse(options[1].commandText),
            .model("gpt-5.6-terra")
        )
    }

    func testSessionOptionsIncludeActionsSavedSessionsAndManualResume() throws {
        let binding = AgentSessionBinding(
            agent: .codex,
            scope: .workspace,
            sessionID: "session-123",
            workingDirectory: "/tmp/project"
        )
        let options = ChatSlashCommandOption.sessionOptions(
            bindings: [binding, binding]
        )

        XCTAssertEqual(options.count, 5)
        XCTAssertEqual(
            options.first(where: { $0.id == "session:status" })?.commandText,
            "/session status"
        )
        let saved = try XCTUnwrap(
            options.first(where: { $0.id == "session:resume:session-123" })
        )
        XCTAssertEqual(saved.commandText, "/session resume session-123")
        XCTAssertEqual(
            try ChatSlashCommandParser.parse(saved.commandText),
            .session(.resume("session-123"))
        )
        XCTAssertEqual(
            options.last?.argumentText,
            "resume "
        )
    }

    func testPaletteFiltersUntilArgumentsBegin() {
        XCTAssertEqual(ChatSlashCommandDescriptor.suggestions(for: "/").count, 6)
        XCTAssertEqual(
            ChatSlashCommandDescriptor.suggestions(for: "/co").map(\.name),
            ["/context", "/compact"]
        )
        XCTAssertEqual(
            ChatSlashCommandDescriptor.suggestions(for: "/h").map(\.name),
            ["/handoff", "/help"]
        )
        XCTAssertEqual(
            ChatSlashCommandDescriptor.suggestions(for: "/help").map(\.name),
            ["/help"]
        )
        XCTAssertTrue(
            ChatSlashCommandDescriptor.suggestions(for: "/model gpt-5.6-sol").isEmpty
        )
        XCTAssertTrue(
            ChatSlashCommandDescriptor.suggestions(for: "/compact ").isEmpty
        )
        XCTAssertEqual(
            ChatSlashCommandDescriptor.suggestions(
                for: "сообщение после первой команды /co"
            ).map(\.name),
            ["/context", "/compact"]
        )
        XCTAssertEqual(
            ChatSlashCommandDescriptor.suggestions(
                for: "сообщение после первой команды /"
            ).count,
            6
        )
        XCTAssertTrue(ChatSlashCommandDescriptor.suggestions(for: "hello").isEmpty)
    }

    func testRecognizedCommandBecomesTokenAfterWhitespace() {
        let compact = ChatSlashCommandDescriptor.recognizedCompletion(in: "/compact ")
        XCTAssertEqual(compact?.command.name, "/compact")
        XCTAssertEqual(compact?.replacementRange, NSRange(location: 0, length: 9))

        let help = ChatSlashCommandDescriptor.recognizedCompletion(in: "/help ")
        XCTAssertEqual(help?.command.name, "/help")
        XCTAssertEqual(help?.replacementRange, NSRange(location: 0, length: 6))

        let model = ChatSlashCommandDescriptor.recognizedCompletion(
            in: "/MODEL gpt-5.6-sol"
        )
        XCTAssertEqual(model?.command.name, "/model")
        XCTAssertEqual(model?.replacementRange, NSRange(location: 0, length: 7))

        let secondCommand = ChatSlashCommandDescriptor.recognizedCompletion(
            in: "сообщение /compact "
        )
        XCTAssertEqual(secondCommand?.command.name, "/compact")
        XCTAssertEqual(
            secondCommand?.replacementRange,
            NSRange(location: 10, length: 9)
        )

        XCTAssertNil(ChatSlashCommandDescriptor.recognizedCompletion(in: "/unknown "))
        XCTAssertNil(ChatSlashCommandDescriptor.recognizedCompletion(in: "/session"))
    }

    func testInsertingSecondCommandPreservesExistingTokenAndText() {
        let existingToken = InlineComposerToken(
            text: "/help",
            utf16Offset: 0
        )
        let text = "сообщение /compact"
        let commandRange = (text as NSString).range(of: "/compact")

        let insertion = InlineComposerContent.insertingToken(
            text: "/compact",
            replacing: commandRange,
            in: text,
            tokens: [existingToken]
        )

        XCTAssertEqual(insertion.text, "сообщение ")
        XCTAssertEqual(insertion.tokens.first, existingToken)
        XCTAssertEqual(insertion.tokens.last?.text, "/compact")
        XCTAssertEqual(insertion.tokens.last?.utf16Offset, 10)
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: insertion.text,
                tokens: insertion.tokens
            ),
            "/help сообщение /compact"
        )
    }

    func testReplacingHelpTokenPreservesIdentityAndPosition() {
        let helpToken = InlineComposerToken(
            text: "/help",
            utf16Offset: 7
        )
        let untouchedToken = InlineComposerToken(
            text: "/context",
            utf16Offset: 0
        )

        let replaced = InlineComposerContent.replacingToken(
            helpToken.id,
            with: "/model",
            in: [untouchedToken, helpToken]
        )

        XCTAssertEqual(replaced[0], untouchedToken)
        XCTAssertEqual(replaced[1].id, helpToken.id)
        XCTAssertEqual(replaced[1].text, "/model")
        XCTAssertEqual(replaced[1].utf16Offset, helpToken.utf16Offset)
    }

    func testTokenAttachmentRangeDoesNotConsumeFollowingPlainText() {
        let attributedText = NSMutableAttributedString(
            attachment: NSTextAttachment()
        )
        attributedText.append(NSAttributedString(string: "текст после команды"))

        XCTAssertEqual(
            InlineComposerContent.tokenAttachmentRange(
                in: attributedText,
                inside: NSRange(location: 0, length: attributedText.length)
            ),
            NSRange(location: 0, length: 1)
        )
        XCTAssertNil(
            InlineComposerContent.tokenAttachmentRange(
                in: attributedText,
                inside: NSRange(location: 1, length: attributedText.length - 1)
            )
        )
    }

    func testInlineTokenSerializationPreservesItsPositionBetweenWords() {
        let token = InlineComposerToken(
            text: "/model",
            utf16Offset: 6
        )

        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: "выбери модель",
                tokens: [token]
            ),
            "выбери /model модель"
        )
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: "выбери модель",
                tokens: [
                    InlineComposerToken(text: "/model", utf16Offset: 0)
                ]
            ),
            "/model выбери модель"
        )
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: "выбери модель",
                tokens: [
                    InlineComposerToken(text: "/model", utf16Offset: 13)
                ]
            ),
            "выбери модель /model"
        )
    }

    func testInlineTokenDropSnapsToWordEdges() {
        let text = "один длинный три"

        XCTAssertEqual(
            InlineComposerContent.nearestWordBoundary(to: 0, in: text),
            0
        )
        XCTAssertEqual(
            InlineComposerContent.nearestWordBoundary(to: 7, in: text),
            5
        )
        XCTAssertEqual(
            InlineComposerContent.nearestWordBoundary(to: 10, in: text),
            12
        )
        XCTAssertEqual(
            InlineComposerContent.nearestWordBoundary(to: 16, in: text),
            16
        )
    }

    func testMovingTokenPlacesItBetweenAndAfterWords() {
        let token = InlineComposerToken(
            text: "/compact",
            utf16Offset: 0
        )
        let text = "один два"

        let betweenWords = InlineComposerContent.movingToken(
            token.id,
            to: 5,
            in: text,
            tokens: [token]
        )
        XCTAssertEqual(betweenWords.first?.utf16Offset, 5)
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: text,
                tokens: betweenWords
            ),
            "один /compact два"
        )

        let afterWords = InlineComposerContent.movingToken(
            token.id,
            to: (text as NSString).length,
            in: text,
            tokens: betweenWords
        )
        XCTAssertEqual(
            afterWords.first?.utf16Offset,
            (text as NSString).length
        )
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: text,
                tokens: afterWords
            ),
            "один два /compact"
        )
    }

    func testMovingOneTokenPreservesOtherTokenAndItsPosition() {
        let context = InlineComposerToken(
            text: "/context",
            utf16Offset: 0
        )
        let compact = InlineComposerToken(
            text: "/compact",
            utf16Offset: 12
        )
        let text = "один два три"

        let moved = InlineComposerContent.movingToken(
            compact.id,
            to: 5,
            in: text,
            tokens: [context, compact]
        )

        XCTAssertEqual(moved[0], context)
        XCTAssertEqual(moved[1].id, compact.id)
        XCTAssertEqual(moved[1].utf16Offset, 5)
        XCTAssertEqual(
            InlineComposerContent.resolvedText(
                text: text,
                tokens: moved
            ),
            "/context один /compact два три"
        )
    }
}
