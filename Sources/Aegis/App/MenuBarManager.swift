import AppKit
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("Aegis.openSettings")
}

@MainActor
final class MenuBarManager: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let settingsStore: SettingsStore
    private let sessionStore: SessionStore
    private let onQuit: () -> Void
    private let onReloadSounds: () -> Void
    private let onPreviewEvent: (SoundEvent) -> Void
    private let onPreviewProfile: (SoundProfile) -> Void
    private let onPreviewFile: (String) -> Void
    private let onShowWelcome: () -> Void
    private let onShowWhatsNew: () -> Void
    private var settingsWindow: NSWindow?

    init(settingsStore: SettingsStore, sessionStore: SessionStore, onReloadSounds: @escaping () -> Void, onPreviewEvent: @escaping (SoundEvent) -> Void, onPreviewProfile: @escaping (SoundProfile) -> Void, onPreviewFile: @escaping (String) -> Void, onShowWelcome: @escaping () -> Void, onShowWhatsNew: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.onReloadSounds = onReloadSounds
        self.onPreviewEvent = onPreviewEvent
        self.onPreviewProfile = onPreviewProfile
        self.onPreviewFile = onPreviewFile
        self.onShowWelcome = onShowWelcome
        self.onShowWhatsNew = onShowWhatsNew
        self.onQuit = onQuit
        super.init()
        setupStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings), name: .openSettings, object: nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Aegis")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let titleItem = NSMenuItem(title: "Aegis v\(version)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Sessions list — refreshed in menuWillOpen
        let sessionsHeader = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
        sessionsHeader.isEnabled = false
        sessionsHeader.tag = TagSessions
        menu.addItem(sessionsHeader)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sound Effects", action: #selector(toggleSound), keyEquivalent: "s")
        soundItem.target = self
        soundItem.state = settingsStore.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let installItem = NSMenuItem(title: "Install Hooks", action: #selector(installHooks), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)

        let whatsNewItem = NSMenuItem(title: "What's New", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)

        let welcomeItem = NSMenuItem(title: "Welcome", action: #selector(showWelcome), keyEquivalent: "")
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Aegis", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the sessions block right before the menu shows so the count
    /// reflects current state — the initial menu is built once and would
    /// otherwise stay frozen at "No active sessions".
    func menuWillOpen(_ menu: NSMenu) {
        refreshSessionsSection(menu: menu)
    }

    private func refreshSessionsSection(menu: NSMenu) {
        // Find the existing header item (tag 100) and remove it + any inserted children up to the next separator.
        guard let headerIdx = menu.items.firstIndex(where: { $0.tag == TagSessions }) else { return }
        // Remove any session entries we inserted previously (they have TagSessionEntry).
        let idx = headerIdx + 1
        while idx < menu.items.count && menu.items[idx].tag == TagSessionEntry {
            menu.removeItem(at: idx)
        }

        let active = Array(sessionStore.activeSessions.values).sorted(by: { $0.startedAt < $1.startedAt })
        let header = menu.items[headerIdx]
        if active.isEmpty {
            header.title = "No active sessions"
        } else {
            header.title = active.count == 1 ? "1 active session" : "\(active.count) active sessions"
            for (offset, session) in active.enumerated() {
                let name = session.displayName.isEmpty ? session.projectName : session.displayName
                let providerLabel = session.provider.displayName
                let item = NSMenuItem(
                    title: "  \(providerLabel) · \(name)",
                    action: #selector(openSessionFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                item.isEnabled = true
                item.tag = TagSessionEntry
                menu.insertItem(item, at: headerIdx + 1 + offset)
            }
        }
    }

    // Stable tags so we can find items when rebuilding sub-sections.
    private let TagSessions = 100
    private let TagSessionEntry = 101

    @objc private func toggleSound() {
        settingsStore.soundEnabled.toggle()
        if let menu = statusItem?.menu,
           let item = menu.items.first(where: { $0.action == #selector(toggleSound) }) {
            item.state = settingsStore.soundEnabled ? .on : .off
        }
    }

    @objc private func openSessionFromMenu(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String,
              let session = sessionStore.sessions[sessionId] else { return }
        TerminalJumper.jump(to: session)
    }

    @objc private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settingsStore: settingsStore, onReloadSounds: onReloadSounds, onPreviewEvent: onPreviewEvent, onPreviewProfile: onPreviewProfile, onPreviewFile: onPreviewFile)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: view)
        window.title = "Aegis Settings"
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func installHooks() {
        // Re-run the same supported-provider installers used at launch.
        _ = CodexInstaller.install()
        _ = ProviderInstaller.installAll()

        let alert = NSAlert()
        alert.messageText = "Hooks installed"
        alert.informativeText = "Re-installed hooks for every detected agent. If an agent was already running, restart it to pick them up."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showWhatsNew() {
        onShowWhatsNew()
    }

    @objc private func showWelcome() {
        onShowWelcome()
    }

    @objc private func quit() {
        onQuit()
    }
}
