import AppKit
import SwiftUI
import Combine

enum CompanionWindowLifecycleAction: Equatable {
    case create
    case destroy
    case none
}

enum CompanionWindowLifecyclePolicy {
    static func action(isEnabled: Bool, hasController: Bool) -> CompanionWindowLifecycleAction {
        switch (isEnabled, hasController) {
        case (true, false): return .create
        case (false, true): return .destroy
        default: return .none
        }
    }
}

final class CompanionPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
    }
}

private final class CompanionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class CompanionWindowController: NSWindowController, NSWindowDelegate {
    private let model: CompanionModel
    private let settingsStore: SettingsStore
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingFrame = false

    private static let basePanelSize = NSSize(width: 116, height: 124)
    private static let positionXKey = "companionWindowOriginX"
    private static let positionYKey = "companionWindowOriginY"

    init(sessionStore: SessionStore, settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.model = CompanionModel(sessionStore: sessionStore)

        let size = Self.panelSize(for: settingsStore.companionScale)
        let panel = CompanionPanel(contentRect: NSRect(origin: .zero, size: size))
        super.init(window: panel)
        panel.delegate = self
        panel.collectionBehavior = Self.collectionBehavior(
            followsActiveWorkspace: settingsStore.companionFollowsActiveWorkspace
        )

        let rootView = CompanionSpriteView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = CompanionHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        restoreOrPlaceWindow()
        bindSettings()
        observeWindowVisibility()
        reconcileVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func handleSessionEvent(_ event: SessionEvent) {
        model.handle(event)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: Self.positionXKey)
        UserDefaults.standard.set(origin.y, forKey: Self.positionYKey)
    }

    private func bindSettings() {
        settingsStore.$companionEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
            .store(in: &cancellables)

        settingsStore.$companionScale
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] scale in self?.resize(to: scale) }
            .store(in: &cancellables)

        settingsStore.$companionFollowsActiveWorkspace
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] follows in
                self?.window?.collectionBehavior = Self.collectionBehavior(
                    followsActiveWorkspace: follows
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clampToVisibleScreen() }
            .store(in: &cancellables)
    }

    private func observeWindowVisibility() {
        guard let panel = window else { return }
        NotificationCenter.default.publisher(
            for: NSWindow.didChangeOcclusionStateNotification,
            object: panel
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refreshAnimationVisibility() }
        .store(in: &cancellables)
    }

    private func reconcileVisibility() {
        guard let panel = window else { return }
        if settingsStore.companionEnabled {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        refreshAnimationVisibility()
    }

    private func refreshAnimationVisibility() {
        guard let panel = window else {
            model.isWindowVisible = false
            return
        }
        model.isWindowVisible = settingsStore.companionEnabled
            && panel.isVisible
            && panel.occlusionState.contains(.visible)
    }

    private func resize(to scale: Double) {
        guard let panel = window else { return }
        let oldFrame = panel.frame
        let newSize = Self.panelSize(for: scale)
        var frame = NSRect(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2,
            width: newSize.width,
            height: newSize.height
        )
        frame = clamped(frame)
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        isApplyingFrame = false
    }

    private func restoreOrPlaceWindow() {
        guard let panel = window else { return }
        let defaults = UserDefaults.standard
        let hasStoredPosition = defaults.object(forKey: Self.positionXKey) != nil
            && defaults.object(forKey: Self.positionYKey) != nil
        let frame: NSRect
        if hasStoredPosition {
            frame = NSRect(
                x: defaults.double(forKey: Self.positionXKey),
                y: defaults.double(forKey: Self.positionYKey),
                width: panel.frame.width,
                height: panel.frame.height
            )
        } else {
            let visible = ScreenDetector.notchScreen.visibleFrame
            frame = NSRect(
                x: visible.maxX - panel.frame.width - 28,
                y: visible.minY + 28,
                width: panel.frame.width,
                height: panel.frame.height
            )
        }
        isApplyingFrame = true
        panel.setFrame(clamped(frame), display: false)
        isApplyingFrame = false
    }

    private func clampToVisibleScreen() {
        guard let panel = window else { return }
        isApplyingFrame = true
        panel.setFrame(clamped(panel.frame), display: true)
        isApplyingFrame = false
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        let targetScreen = NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        } ?? ScreenDetector.notchScreen
        let visible = targetScreen.visibleFrame.insetBy(dx: 8, dy: 8)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
            y: min(max(frame.minY, visible.minY), visible.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func panelSize(for scale: Double) -> NSSize {
        let clamped = min(max(scale, 0.75), 1.50)
        return NSSize(
            width: basePanelSize.width * clamped,
            height: basePanelSize.height * clamped
        )
    }

    private static func collectionBehavior(followsActiveWorkspace: Bool) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        if followsActiveWorkspace {
            behavior.insert(.canJoinAllSpaces)
        }
        return behavior
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
