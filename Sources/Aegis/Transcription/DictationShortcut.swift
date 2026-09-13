import AppKit

enum DictationMode: String, CaseIterable {
    case toggle, hold
    var title: String { self == .toggle ? "Toggle recording" : "Hold to dictate" }
}

enum DictationShiftKey: String, CaseIterable {
    case either, left, right
    var title: String {
        switch self {
        case .either: return "Either Shift key"
        case .left: return "Left Shift"
        case .right: return "Right Shift"
        }
    }
    func accepts(_ code: UInt16) -> Bool {
        (code == 56 && self != .right) || (code == 60 && self != .left)
    }
}

struct DictationShortcutState {
    enum Action: Equatable { case start, stop, cancel }
    var mode: DictationMode = .toggle
    var key: DictationShiftKey = .either
    private(set) var recording = false
    private var pressed: UInt16?
    private var pressedAt: TimeInterval = 0
    private var lastTap: TimeInterval?
    private var contaminated = false

    init(mode: DictationMode = .toggle, key: DictationShiftKey = .either) {
        self.mode = mode
        self.key = key
    }

    mutating func reset() {
        self = Self(mode: mode, key: key)
    }

    mutating func applicationChanged() {
        if !recording { reset() }
    }

    mutating func combination() -> Action? {
        contaminated = true
        lastTap = nil
        if mode == .hold && recording {
            recording = false
            return .cancel
        }
        return nil
    }

    mutating func holdElapsed(at time: TimeInterval) -> Action? {
        guard mode == .hold, pressed != nil, !contaminated, !recording,
              time - pressedAt >= 0.25 else { return nil }
        recording = true
        return .start
    }

    mutating func shift(code: UInt16, down: Bool, at time: TimeInterval, modified: Bool = false) -> Action? {
        guard key.accepts(code) else { return combination() }
        if down {
            if pressed == code { return nil }
            guard pressed == nil else { return combination() }
            pressed = code
            pressedAt = time
            contaminated = modified
            if modified { lastTap = nil }
            return nil
        }
        guard pressed == code else { return nil }
        pressed = nil
        if mode == .hold {
            if recording { recording = false; return .stop }
            return nil
        }
        guard !contaminated, !modified, time - pressedAt <= 0.25 else {
            lastTap = nil
            return nil
        }
        if let previous = lastTap, pressedAt - previous <= 0.35 {
            lastTap = nil
            recording.toggle()
            return recording ? .start : .stop
        }
        lastTap = time
        return nil
    }
}

@MainActor
final class GlobalDictationShortcut {
    var onAction: ((DictationShortcutState.Action) -> Void)?
    var onFailure: (() -> Void)?
    var state = DictationShortcutState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var holdTask: Task<Void, Never>?
    private var keysDown = Set<UInt16>()

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalDictationShortcut>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.receive(type, event: event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func reset() {
        holdTask?.cancel()
        state.reset()
        keysDown.removeAll()
    }

    func applicationChanged() {
        guard !state.recording else { return }
        holdTask?.cancel()
        state.applicationChanged()
        keysDown.removeAll()
    }

    func stop() {
        reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    private func receive(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            onAction?(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onFailure?()
            return
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            keysDown.insert(code)
            if code == 53 { reset(); onAction?(.cancel); return }
            if let action = state.combination() { onAction?(action) }
        } else if type == .keyUp {
            keysDown.remove(code)
        } else if type == .flagsChanged {
            guard code == 56 || code == 60 else {
                if let action = state.combination() { onAction?(action) }
                return
            }
            // Device-specific bits distinguish releasing one Shift while the other remains down.
            let down = event.flags.rawValue & (code == 56 ? 0x02 : 0x04) != 0
            let modified = !event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
                || !keysDown.isEmpty
            if let action = state.shift(code: code, down: down, at: ProcessInfo.processInfo.systemUptime, modified: modified) {
                onAction?(action)
            }
            holdTask?.cancel()
            if down && state.mode == .hold {
                holdTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, let self else { return }
                    if let action = state.holdElapsed(at: ProcessInfo.processInfo.systemUptime) { onAction?(action) }
                }
            }
        }
    }
}
