import XCTest
@testable import ThirdHand

final class AgentQuestionSuggestionsTests: XCTestCase {
    func testExtractsNumberedChoicesFromQuestion() {
        XCTAssertEqual(
            AgentQuestionSuggestions.choices(
                from: "Какой вариант использовать?\n1. SwiftData\n2. SQLite\n3. JSON"
            ),
            ["SwiftData", "SQLite", "JSON"]
        )
    }

    func testOffersYesAndNoForConfirmation() {
        XCTAssertEqual(
            AgentQuestionSuggestions.choices(from: "Продолжить и запустить тесты?"),
            ["Да", "Нет"]
        )
    }

    func testDoesNotInventAnswersForOpenQuestionOrOrdinaryList() {
        XCTAssertTrue(
            AgentQuestionSuggestions.choices(from: "Как назвать новый модуль?").isEmpty
        )
        XCTAssertTrue(
            AgentQuestionSuggestions.choices(from: "Готово:\n- UI\n- тесты").isEmpty
        )
    }

    func testOpenQuestionRequiresUserResponseEvenWithoutSuggestedChoices() {
        let question = "Как назвать новый модуль?"

        XCTAssertTrue(AgentQuestionSuggestions.choices(from: question).isEmpty)
        XCTAssertTrue(AgentQuestionSuggestions.requiresUserResponse(from: question))
        XCTAssertFalse(
            AgentQuestionSuggestions.requiresUserResponse(
                from: "Готово: сборка и тесты прошли."
            )
        )
    }
}
