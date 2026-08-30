import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindowController: NotchWindowController?
    private var companionWindowController: CompanionWindowController?
    private var menuBarManager: MenuBarManager?
    private var onboardingController: OnboardingWindowController?
    private var whatsNewController: WhatsNewWindowController?
    private let sessionStore = SessionStore()
    private let socketServer = SocketServer()
    private let soundEngine = SoundEngine()
    private let settingsStore = SettingsStore()
    private let executionPowerController = AgentExecutionPowerController()
    private let systemPowerConditionMonitor = SystemPowerConditionMonitor()
    private lazy var hermesVoiceHandoffController = HermesVoiceHandoffController(settingsStore: settingsStore)
    private let rateLimitStore = RateLimitStore()
    private let codexDesktopWatcher = CodexDesktopSessionWatcher()
    private let hermesDesktopWatcher = HermesDesktopSessionWatcher()
    private var cancellables = Set<AnyCancellable>()

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("App launching...")
        // Hide dock icon (LSUIElement backup)
        NSApp.setActivationPolicy(.accessory)

        // Wire up socket → session store → sound
        socketServer.onMessage = { [weak self] message, respond, respondRaw in
            guard let self else { return }
            Log.info("Received: \(message.hookEvent) session=\(message.sessionId.prefix(8))")
            self.sessionStore.handleMessage(message, respond: respond, respondRaw: respondRaw)
        }

        sessionStore.onEvent
            .sink { [weak self] event in
                self?.soundEngine.play(event)
                self?.notchWindowController?.handleSessionEvent(event)
                self?.companionWindowController?.handleSessionEvent(event)
            }
            .store(in: &cancellables)

        sessionStore.onExecutionEvent
            .sink { [weak self] event in
                self?.executionPowerController.handle(event)
            }
            .store(in: &cancellables)

        settingsStore.$keepAwakeMode
            .sink { [weak self] mode in
                self?.executionPowerController.update(mode: mode)
            }
            .store(in: &cancellables)

        systemPowerConditionMonitor.onChange = { [weak self] conditions in
            self?.executionPowerController.update(conditions: conditions)
        }
        systemPowerConditionMonitor.start()

        // Sync sound settings
        settingsStore.$soundEnabled
            .sink { [weak self] enabled in self?.soundEngine.setEnabled(enabled) }
            .store(in: &cancellables)
        settingsStore.$soundVolume
            .sink { [weak self] volume in self?.soundEngine.setVolume(volume) }
            .store(in: &cancellables)
        settingsStore.$soundProfile
            .sink { [weak self] profile in self?.soundEngine.setProfile(profile) }
            .store(in: &cancellables)
        settingsStore.$soundEventVolumes
            .sink { [weak self] volumes in self?.soundEngine.applyEventVolumes(volumes) }
            .store(in: &cancellables)
        // Per-event sound assignments (Default / Off / a library file). The
        // @Published publisher emits the current value on subscribe, so this
        // also applies the initial assignments at startup.
        settingsStore.$soundAssignments
            .sink { [weak self] map in self?.soundEngine.applyAssignments(map) }
            .store(in: &cancellables)

        // Create notch window
        notchWindowController = NotchWindowController(
            sessionStore: sessionStore,
            settingsStore: settingsStore,
            rateLimitStore: rateLimitStore
        )
        notchWindowController?.showWindow(nil)
        settingsStore.$companionEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.reconcileCompanionWindow(isEnabled: enabled)
            }
            .store(in: &cancellables)
        let screen = ScreenDetector.notchScreen
        Log.info("Notch window shown, frame: \(notchWindowController?.window?.frame ?? .zero)")
        Log.info("Screen frame: \(screen.frame)")
        Log.info("Screen visibleFrame: \(screen.visibleFrame)")
        Log.info("SafeAreaInsets: top=\(screen.safeAreaInsets.top) bottom=\(screen.safeAreaInsets.bottom)")
        Log.info("Notch height: \(ScreenDetector.notchHeight), hasNotch: \(ScreenDetector.hasNotch)")
        Log.info("Window level: \(notchWindowController?.window?.level.rawValue ?? -1)")

        // Menu bar
        menuBarManager = MenuBarManager(
            settingsStore: settingsStore,
            sessionStore: sessionStore,
            onReloadSounds: { [weak self] in self?.soundEngine.reloadSounds() },
            onPreviewEvent: { [weak self] ev in self?.soundEngine.preview(ev) },
            onPreviewProfile: { [weak self] profile in self?.soundEngine.previewProfile(profile) },
            onPreviewFile: { [weak self] name in self?.soundEngine.previewFile(name) },
            onShowWelcome: { [weak self] in self?.showOnboarding() },
            onShowWhatsNew: { [weak self] in self?.showWhatsNew() },
            onQuit: { NSApp.terminate(nil) }
        )

        // Start socket server
        socketServer.start()
        Log.info("Socket server started")

        // Setup directories
        setupDirectories()

        // Auto-install hooks for every supported provider on every launch.
        // Installers are idempotent and pre-stage Codex config even if the user
        // doesn't have Codex installed yet, so it "just works" when they add it.
        Task.detached {
            _ = CodexInstaller.install()
            _ = ProviderInstaller.installAll()
        }

        codexDesktopWatcher.onMessage = { [weak self] message in
            Log.info("Codex Desktop: \(message.hookEvent) session=\(message.sessionId.prefix(8))")
            self?.sessionStore.handleMessage(message, respond: nil)
        }
        codexDesktopWatcher.start()

        hermesDesktopWatcher.onMessage = { [weak self] message in
            Log.info("Hermes Desktop: \(message.hookEvent) session=\(message.sessionId.prefix(8))")
            self?.sessionStore.handleMessage(message, respond: nil, origin: .durableProviderState)
        }
        hermesDesktopWatcher.start()
        hermesVoiceHandoffController.start()

        // Never activate a first-run window automatically: the notch is a
        // background utility and must not steal focus. Welcome and What's New
        // remain available from the menu bar.
        if !settingsStore.hasSeenThemeOnboarding {
            settingsStore.hasSeenThemeOnboarding = true
        }
        settingsStore.lastWhatsNewVersion = currentVersion

    }

    private func reconcileCompanionWindow(isEnabled: Bool) {
        switch CompanionWindowLifecyclePolicy.action(
            isEnabled: isEnabled,
            hasController: companionWindowController != nil
        ) {
        case .create:
            companionWindowController = CompanionWindowController(
                sessionStore: sessionStore,
                settingsStore: settingsStore
            )
        case .destroy:
            companionWindowController?.close()
            companionWindowController = nil
        case .none:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        executionPowerController.stop()
        systemPowerConditionMonitor.stop()
        codexDesktopWatcher.stop()
        hermesDesktopWatcher.stop()
        hermesVoiceHandoffController.stop()
        socketServer.stop()
        soundEngine.shutdown()
        cleanupPidFile()
        Log.shutdown()
    }

    private func setupDirectories() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [
            home.appendingPathComponent(".aegis/bin"),
            home.appendingPathComponent(".aegis/run"),
            home.appendingPathComponent(".aegis/cache"),
            home.appendingPathComponent(".aegis/sound-packs"),
        ]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Write PID
        let pidFile = home.appendingPathComponent(".aegis/run/aegis.pid")
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private func showOnboarding() {
        onboardingController = OnboardingWindowController(
            settingsStore: settingsStore,
            onComplete: { [weak self] in
                self?.onboardingController = nil
            }
        )
        onboardingController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showWhatsNew() {
        whatsNewController = WhatsNewWindowController(
            version: currentVersion,
            onClose: { [weak self] in
                guard let self else { return }
                self.settingsStore.lastWhatsNewVersion = self.currentVersion
                self.whatsNewController = nil
            }
        )
        whatsNewController?.showWindow(nil)
    }

    private func cleanupPidFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pidFile = home.appendingPathComponent(".aegis/run/aegis.pid")
        try? FileManager.default.removeItem(at: pidFile)
    }
}
