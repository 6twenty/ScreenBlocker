import UserNotifications

/// The subset of notification center behaviour ScheduleManager relies on.
/// Abstracted so tests can run without a bundle (UNUserNotificationCenter requires one).
protocol NotificationScheduling {
    func add(_ request: UNNotificationRequest)
    func removeAllPendingNotificationRequests()
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func getDeliveredNotificationIdentifiers(completion: @escaping ([String]) -> Void)
}

struct SystemNotificationCenter: NotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func add(_ request: UNNotificationRequest) {
        center.add(request)
    }

    func removeAllPendingNotificationRequests() {
        center.removeAllPendingNotificationRequests()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func getDeliveredNotificationIdentifiers(completion: @escaping ([String]) -> Void) {
        center.getDeliveredNotifications { notifications in
            completion(notifications.map { $0.request.identifier })
        }
    }
}
