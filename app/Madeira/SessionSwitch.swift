// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Julian Scanlan
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import UIKit
import UserNotifications

// One Wine session per app run (LibraryModel.sessionsThisRun): a second game needs a
// fresh process. Instead of only asking people to swipe Madeira away and find the
// game again, the restart alert offers Close and Start: the game whose Play was held
// is noted, Madeira closes and a notification brings it back, and the game starts
// once the library is up, the way a Home Screen shortcut does
// (ContentView.launchPendingSwitch). Opening Madeira from the Home Screen within ten
// minutes starts it too. Log tag: [session-switch].
@MainActor
enum SessionSwitch {
    /// The entry whose Play the one-session rule held, for the restart alert.
    static var held: LibraryEntry?

    private static let key = "madeiraSessionSwitch"
    private static let notification = "madeira.session-switch"

    /// Notes `entry`, closes Madeira and asks for the notification that brings it back.
    static func restart(into entry: LibraryEntry) {
        UserDefaults.standard.set(["id": entry.id.uuidString, "at": Date().timeIntervalSince1970], forKey: key)
        UserDefaults.standard.synchronize()   // Madeira exits right after this
        LogStore.shared.log("[session-switch] closing to start \(entry.title)")
        let title = entry.title, id = notification
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return DispatchQueue.main.async { exit(0) } }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Tap to open Madeira and start it."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
    }

    /// The entry to start now, once: nil when none was noted in the last ten minutes.
    static func take() -> UUID? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification])
        guard let id = (saved["id"] as? String).flatMap(UUID.init(uuidString:)),
              let at = saved["at"] as? Double, Date().timeIntervalSince1970 - at < 600 else { return nil }
        return id
    }
}
