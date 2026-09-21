//
//  ScheduleExpirationWarningNotificationOperation.swift
//  SideStore
//
//  Created by Magesh K on 30/07/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import UserNotifications
import Foundation

final class ScheduleExpirationWarningNotificationOperation: BaseStandaloneOperation<StandaloneOperationContext, Bool>, @unchecked Sendable {
    let installedApp: InstalledApp

    init(installedApp: InstalledApp, context: StandaloneOperationContext) throws {
        self.installedApp = installedApp
        try super.init(context: context)
    }

    override func execute(parentProgress: Progress?) async throws -> Bool {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[ScheduleExpirationWarningNotificationOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[ScheduleExpirationWarningNotificationOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        let center = UNUserNotificationCenter.current()
        let now = Date()
        var expirationDate = Date()
        self.setProgress(30)
        installedApp.managedObjectContext?.performAndWait {
            expirationDate = installedApp.expirationDate
        }

        let identifier = "anderstore.signature.2d"
        let allIdentifiers = [
            identifier,
            "anderstore.signature.1d",
            "\(AppManager.expirationWarningNotificationID).24h",
            "\(AppManager.expirationWarningNotificationID).6h",
            "\(AppManager.expirationWarningNotificationID).0h"
        ]
        self.setProgress(50)
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: Array(allIdentifiers.dropFirst()))

        #if !os(tvOS)
        let targetDate = expirationDate.addingTimeInterval(-48 * 60 * 60)
        let triggerInterval = targetDate.timeIntervalSince(now)
        // The host schedules an immediate reminder once when this point is already in the past.
        // Core only owns the future request, preventing duplicate foreground notifications.
        if triggerInterval > 0 {
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("lc.account.reminderTitle", comment: "")
            content.body = NSLocalizedString("lc.account.reminderBody", comment: "")
            content.sound = .default
            content.userInfo = ["anderAction": "renewSignature"]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: triggerInterval, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

            try await center.add(request)
        }
        #else
        NotificationCenter.default.post(name: NSNotification.Name("TVTopShelfItemsDidChangeNotification"), object: nil)
        #endif
        self.setProgress(100)
        return true
    }
}
