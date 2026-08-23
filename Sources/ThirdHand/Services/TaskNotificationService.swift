@preconcurrency import UserNotifications
import Foundation

enum TaskNotificationKind: String, CaseIterable, Sendable {
    case question
    case attention
    case resultReady
    case taskCompleted

    var title: String {
        switch self {
        case .question: "Требуется ответ"
        case .attention: "Задача требует внимания"
        case .resultReady: "Ответ агента готов"
        case .taskCompleted: "Задача завершена"
        }
    }

    var preferenceKey: String {
        switch self {
        case .question: "notificationQuestionsEnabled"
        case .attention: "notificationAttentionEnabled"
        case .resultReady: "notificationResultsEnabled"
        case .taskCompleted: "notificationCompletionEnabled"
        }
    }
}

struct TaskNotificationEvent: Sendable {
    let taskID: UUID
    let taskTitle: String
    let kind: TaskNotificationKind
}

protocol TaskNotificationSending: Sendable {
    func requestAuthorization() async -> Bool
    func post(_ event: TaskNotificationEvent) async
    func removeNotifications(taskID: UUID) async
}

actor SystemTaskNotificationService: TaskNotificationSending {
    static let shared = SystemTaskNotificationService()

    func requestAuthorization() async -> Bool {
        guard Self.isRunningFromApplicationBundle else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [
                .alert,
                .badge,
                .sound
            ])
        } catch {
            return false
        }
    }

    func post(_ event: TaskNotificationEvent) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "notificationsEnabled"),
              Self.preferenceEnabled(event.kind.preferenceKey, defaults: defaults),
              Self.isRunningFromApplicationBundle
        else {
            return
        }
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = event.kind.title
        content.body = event.taskTitle
        content.userInfo = ["taskID": event.taskID.uuidString]
        if event.kind == .question || event.kind == .attention {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: Self.identifier(
                taskID: event.taskID,
                kind: event.kind
            ),
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func removeNotifications(taskID: UUID) async {
        guard Self.isRunningFromApplicationBundle else { return }
        let center = UNUserNotificationCenter.current()
        let identifiers = TaskNotificationKind.allCases.map {
            Self.identifier(taskID: taskID, kind: $0)
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func preferenceEnabled(
        _ key: String,
        defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    private static func identifier(
        taskID: UUID,
        kind: TaskNotificationKind
    ) -> String {
        "thirdhand.\(taskID.uuidString).\(kind.rawValue)"
    }

    private static var isRunningFromApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
