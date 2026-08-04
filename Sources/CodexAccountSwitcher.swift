import AppKit
import Carbon.HIToolbox
import Foundation

enum CodexProfile {
    case primary
    case secondary

    var name: String {
        switch self {
        case .primary: "Primary"
        case .secondary: "Secondary"
        }
    }

}

private let hotKeySignature: OSType = 0x43445841 // CDXA
private let primaryHotKeyID: UInt32 = 1
private let secondaryHotKeyID: UInt32 = 2
private let launcherActionNotification = Notification.Name(
    "com.edihasaj.codex-account-switcher.action"
)

private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        switch hotKeyID.id {
        case primaryHotKeyID:
            delegate.switchTo(.primary)
        case secondaryHotKeyID:
            delegate.switchTo(.secondary)
        default:
            break
        }
    }
    return noErr
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var statusItem: NSStatusItem?
    private var primaryItem: NSMenuItem?
    private var secondaryItem: NSMenuItem?
    private var quitPrimaryItem: NSMenuItem?
    private var quitSecondaryItem: NSMenuItem?
    private var eventHandler: EventHandlerRef?
    private var primaryHotKey: EventHotKeyRef?
    private var secondaryHotKey: EventHotKeyRef?
    private var statusTimer: Timer?

    private var installedAppURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("Contents/MacOS/ChatGPT").path
            )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        registerHotKeys()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleLauncherAction),
            name: launcherActionNotification,
            object: nil
        )
        updateStatus()
        statusTimer = Timer.scheduledTimer(
            withTimeInterval: 3,
            repeats: true
        ) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        if let primaryHotKey { UnregisterEventHotKey(primaryHotKey) }
        if let secondaryHotKey { UnregisterEventHotKey(secondaryHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatus()
    }

    func switchTo(_ profile: CodexProfile) {
        open(profile)
    }

    private func open(_ profile: CodexProfile) {
        if let pid = processID(for: profile) {
            activate(pid)
            return
        }

        guard let installedAppURL else {
            showFailure("The installed Codex app was not found.")
            return
        }

        let codexHome: URL
        var arguments = ["-n", installedAppURL.path]

        switch profile {
        case .primary:
            codexHome = home.appendingPathComponent(".codex")
            arguments += ["--env", "CODEX_HOME=\(codexHome.path)"]
        case .secondary:
            codexHome = home.appendingPathComponent(".codex-work")
            let appData = home.appendingPathComponent(
                "Library/Application Support/Codex Second"
            )
            do {
                try FileManager.default.createDirectory(
                    at: appData,
                    withIntermediateDirectories: true
                )
            } catch {
                showFailure(error.localizedDescription)
                return
            }
            arguments += [
                "--env", "CODEX_HOME=\(codexHome.path)",
                "--args", "--user-data-dir=\(appData.path)",
            ]
        }

        do {
            try FileManager.default.createDirectory(
                at: codexHome,
                withIntermediateDirectories: true
            )
            let result = try run("/usr/bin/open", arguments: arguments)
            guard result.status == 0 else {
                showFailure("Codex \(profile.name) could not be launched.")
                return
            }
            focusWhenReady(profile, attemptsRemaining: 24)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "person.2.circle",
            accessibilityDescription: "Codex accounts"
        )
        item.button?.toolTip = "Codex accounts"

        let menu = NSMenu()
        menu.delegate = self

        let primary = NSMenuItem(
            title: "Open or Focus Primary",
            action: #selector(switchToPrimary),
            keyEquivalent: "1"
        )
        primary.keyEquivalentModifierMask = [.command, .option]
        primary.target = self
        menu.addItem(primary)
        primaryItem = primary

        let secondary = NSMenuItem(
            title: "Open or Focus Secondary",
            action: #selector(switchToSecondary),
            keyEquivalent: "2"
        )
        secondary.keyEquivalentModifierMask = [.command, .option]
        secondary.target = self
        menu.addItem(secondary)
        secondaryItem = secondary

        menu.addItem(.separator())
        let both = NSMenuItem(
            title: "Open Both",
            action: #selector(openBoth),
            keyEquivalent: ""
        )
        both.target = self
        menu.addItem(both)

        menu.addItem(.separator())
        let quitPrimary = NSMenuItem(
            title: "Quit Primary",
            action: #selector(quitPrimary),
            keyEquivalent: ""
        )
        quitPrimary.target = self
        menu.addItem(quitPrimary)
        quitPrimaryItem = quitPrimary

        let quitSecondary = NSMenuItem(
            title: "Quit Secondary",
            action: #selector(quitSecondary),
            keyEquivalent: ""
        )
        quitSecondary.target = self
        menu.addItem(quitSecondary)
        quitSecondaryItem = quitSecondary

        menu.addItem(.separator())
        let quitSwitcher = NSMenuItem(
            title: "Quit Account Switcher",
            action: #selector(quitSwitcher),
            keyEquivalent: "q"
        )
        quitSwitcher.target = self
        menu.addItem(quitSwitcher)

        item.menu = menu
        statusItem = item
    }

    private func registerHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            pointer,
            &eventHandler
        )

        let modifiers = UInt32(cmdKey | optionKey)
        let primaryID = EventHotKeyID(signature: hotKeySignature, id: primaryHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            modifiers,
            primaryID,
            GetApplicationEventTarget(),
            0,
            &primaryHotKey
        )

        let secondaryID = EventHotKeyID(signature: hotKeySignature, id: secondaryHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_2),
            modifiers,
            secondaryID,
            GetApplicationEventTarget(),
            0,
            &secondaryHotKey
        )
    }

    private func processID(for profile: CodexProfile) -> pid_t? {
        guard let executable = installedAppURL?
            .appendingPathComponent("Contents/MacOS/ChatGPT").path else {
            return nil
        }

        let escapedExecutable = NSRegularExpression.escapedPattern(for: executable)
        let pattern: String
        switch profile {
        case .primary:
            pattern = "^\(escapedExecutable)$"
        case .secondary:
            let appData = NSRegularExpression.escapedPattern(
                for: home.appendingPathComponent(
                    "Library/Application Support/Codex Second"
                ).path
            )
            pattern = "^\(escapedExecutable) --user-data-dir=\(appData)($| )"
        }

        guard let result = try? run("/usr/bin/pgrep", arguments: ["-f", pattern]),
              result.status == 0,
              let first = result.output.split(separator: "\n").first,
              let pid = pid_t(first) else {
            return nil
        }
        return pid
    }

    private func focusWhenReady(_ profile: CodexProfile, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            showFailure("Codex \(profile.name) started but could not be focused.")
            return
        }
        if let pid = processID(for: profile) {
            activate(pid)
            updateStatus()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.focusWhenReady(profile, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func activate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateAllWindows])
    }

    private func terminate(_ profile: CodexProfile) {
        guard let pid = processID(for: profile) else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateStatus()
        }
    }

    private func updateStatus() {
        let primaryRunning = processID(for: .primary) != nil
        let secondaryRunning = processID(for: .secondary) != nil
        primaryItem?.title = "\(primaryRunning ? "●" : "○") Open or Focus Primary"
        secondaryItem?.title = "\(secondaryRunning ? "●" : "○") Open or Focus Secondary"
        quitPrimaryItem?.isEnabled = primaryRunning
        quitSecondaryItem?.isEnabled = secondaryRunning
        statusItem?.button?.image = NSImage(
            systemSymbolName: primaryRunning && secondaryRunning
                ? "person.2.circle.fill"
                : "person.2.circle",
            accessibilityDescription: "Codex accounts"
        )
    }

    private func run(
        _ executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }

    private func showFailure(_ message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Codex Account Switcher"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func switchToPrimary() { switchTo(.primary) }
    @objc private func switchToSecondary() { switchTo(.secondary) }

    @objc private func handleLauncherAction(_ notification: Notification) {
        guard let action = notification.object as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch action {
            case "primary":
                self?.switchTo(.primary)
            case "secondary":
                self?.switchTo(.secondary)
            case "both":
                self?.openBoth()
            default:
                break
            }
        }
    }

    @objc private func openBoth() {
        open(.primary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.open(.secondary)
        }
    }

    @objc private func quitPrimary() { terminate(.primary) }
    @objc private func quitSecondary() { terminate(.secondary) }
    @objc private func quitSwitcher() { NSApplication.shared.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
