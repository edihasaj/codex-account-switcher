import AppKit
import Foundation

private let switcherBundleIdentifier = "com.edihasaj.codex-account-switcher"
private let actionNotification = Notification.Name(
    "com.edihasaj.codex-account-switcher.action"
)

guard let action = Bundle.main.object(
    forInfoDictionaryKey: "CodexSwitcherAction"
) as? String else {
    exit(1)
}

if NSRunningApplication.runningApplications(
    withBundleIdentifier: switcherBundleIdentifier
).isEmpty {
    let switcherURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Codex Account Switcher.app")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", switcherURL.path]
    try? process.run()
    process.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.75)
}

DistributedNotificationCenter.default().postNotificationName(
    actionNotification,
    object: action,
    userInfo: nil,
    deliverImmediately: true
)
