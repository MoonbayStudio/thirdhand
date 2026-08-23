import AppKit
@preconcurrency import UserNotifications

@MainActor
final class ThirdHandAppDelegate:
    NSObject,
    NSApplicationDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    var onOpenTask: ((UUID) -> Void)? {
        didSet {
            guard let pendingTaskID, let onOpenTask else { return }
            self.pendingTaskID = nil
            onOpenTask(pendingTaskID)
        }
    }
    var currentTaskID: UUID?
    private var pendingTaskID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let taskID = Self.taskID(
            from: notification.request.content.userInfo
        )
        completionHandler(
            taskID == currentTaskID
                ? []
                : [.banner, .list, .sound]
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskID = Self.taskID(
            from: response.notification.request.content.userInfo
        )
        completionHandler()

        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if let taskID {
                if let onOpenTask = self?.onOpenTask {
                    onOpenTask(taskID)
                } else {
                    self?.pendingTaskID = taskID
                }
            }
        }
    }

    private static func taskID(
        from userInfo: [AnyHashable: Any]
    ) -> UUID? {
        (userInfo["taskID"] as? String)
            .flatMap(UUID.init(uuidString:))
    }
}
