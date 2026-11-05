import Foundation

/// Shared by the CLI and agent; hiding the icon never stops disk monitoring.
enum Ext4MenuVisibility {
    static let preferenceKey = "showMenuBarIcon"
    static let changed = Notification.Name("dev.h3ct0r.ext4mac.menuBarVisibility")

    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: preferenceKey) as? Bool) ?? true
    }

    static func save(_ visible: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: preferenceKey)
        defaults.synchronize()
    }

    static func command(_ arguments: [String]) -> Int32 {
        guard arguments.count <= 1 else { return usage() }
        switch arguments.first ?? "status" {
        case "show", "hide":
            let visible = arguments[0] == "show"
            save(visible)
            DistributedNotificationCenter.default().postNotificationName(
                changed, object: visible ? "show" : "hide", userInfo: nil,
                deliverImmediately: true)
            print(visible ? "menu bar icon shown" : "menu bar icon hidden; background monitoring continues")
            return 0
        case "status":
            print(isVisible() ? "shown" : "hidden")
            return 0
        default:
            return usage()
        }
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("Usage: Ext4Mac menu-bar [show|hide|status]\n".utf8))
        return 1
    }
}
