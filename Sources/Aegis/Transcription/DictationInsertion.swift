import AppKit
import ApplicationServices

struct DictationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DictationCaptureError: LocalizedError {
    case accessDenied, secureField

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Allow Aegis in System Settings > Privacy & Security > Accessibility."
        case .secureField: return "Dictation is unavailable in password fields."
        }
    }
}

struct DictationInsertionSnapshot {
    let text: String?
    let selection: NSRange?

    func replacingSelection(with transcript: String, currentText: String?) throws -> String? {
        guard text == nil || currentText == text else {
            throw DictationFailure(message: "The original text changed while you were dictating. Copy your transcript to keep those edits.")
        }
        guard let text, let selection else { return nil }
        let length = (text as NSString).length
        guard currentText == text, selection.location >= 0, selection.length >= 0,
              selection.location <= length, selection.length <= length - selection.location else {
            throw DictationFailure(message: "The original text changed while you were dictating. Copy your transcript to keep those edits.")
        }
        return Self.replacing(selection, in: text, with: transcript)
    }

    static func replacing(_ range: NSRange, in text: String, with transcript: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: transcript)
    }

    static func isValidRange(_ range: NSRange, in text: String) -> Bool {
        let length = (text as NSString).length
        return range.location >= 0 && range.length >= 0 &&
               range.location <= length && range.length <= length - range.location
    }

    /// Decide where Paste should land. Prefers the live caret ("where I am right now").
    /// Falls back to the capture-time snapshot when the live caret collapsed to the
    /// start of unchanged text (a common artifact of programmatic refocusing), and to
    /// end-of-text when no cursor is exposed at all — never leave the caret at 0.
    static func effectiveInsertionRange(
        snapshotSelection: NSRange?,
        snapshotText: String?,
        liveSelection: NSRange?,
        currentText: String?
    ) -> NSRange? {
        if let live = liveSelection, let current = currentText, isValidRange(live, in: current) {
            if live.location == 0, live.length == 0,
               let snapshot = snapshotSelection, snapshot.location != 0,
               isValidRange(snapshot, in: current),
               snapshotText == nil || snapshotText == current {
                return snapshot
            }
            return live
        }
        let reference = currentText ?? snapshotText
        if let snapshot = snapshotSelection, let reference, isValidRange(snapshot, in: reference) {
            return snapshot
        }
        if let current = currentText {
            let length = (current as NSString).length
            return NSRange(location: length, length: 0)
        }
        return nil
    }
}

@MainActor
struct DictationInsertion {
    let application: NSRunningApplication
    let element: AXUIElement
    let window: AXUIElement?
    let snapshot: DictationInsertionSnapshot

    static func capture() throws -> Self {
        guard AXIsProcessTrusted() else {
            throw DictationCaptureError.accessDenied
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw DictationFailure(message: "Focus a text field before dictating.")
        }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(application.processIdentifier)
        // Chromium apps may expose their editor only after accessibility is requested.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw DictationFailure(message: "This app does not expose a focused text field.")
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        guard role as? String != kAXSecureTextFieldSubrole else {
            throw DictationCaptureError.secureField
        }
        var elementRole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &elementRole)
        let text = text(in: element)
        let selection = selectedRange(in: element)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(elementRole as? String ?? "") || selection != nil else {
            throw DictationFailure(message: "Focus a text field before dictating.")
        }
        var windowValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue)
        let window = windowValue.flatMap { value -> AXUIElement? in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        let snapshot = DictationInsertionSnapshot(text: text, selection: selection)
        _ = try snapshot.replacingSelection(with: "", currentText: text)
        Log.info("Dictation capture role=\(elementRole as? String ?? "?") textLength=\((text as NSString?)?.length ?? -1) selection=\(String(describing: selection))")
        return Self(application: application, element: element, window: window, snapshot: snapshot)
    }

    private func validateFocus() throws {
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw DictationFailure(message: "Could not return to the original app. Your transcript is ready to copy.")
        }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(application.processIdentifier)
        if let window {
            var focusedWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
                  let focusedWindow, CFEqual(focusedWindow, window) else {
                throw DictationFailure(message: "The original window is not focused. Your transcript is ready to copy.")
            }
        }
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFEqual(value, element) else {
            throw DictationFailure(message: "The original field is no longer available. Your transcript is ready to copy.")
        }
    }

    private static func text(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func restoreFocus(requiresSettling: Bool) async throws {
        if !requiresSettling, (try? validateFocus()) != nil { return }
        guard !application.isTerminated else {
            throw DictationFailure(message: "The original app closed. Your transcript is ready to copy.")
        }
        application.activate(options: [])
        if let window {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Log.info("Dictation window raise pid=\(application.processIdentifier) result=\(result.rawValue)")
        }
        try await Self.waitForStableFocus {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try validateFocus()
        }
        // Reapply focus after activation and the Space transition have settled.
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try validateFocus()
    }

    static func waitForStableFocus(_ focus: () throws -> Void) async throws {
        var stableChecks = 0
        // ponytail: 600ms settling covers normal Space animations; use transition tracking if longer animations need support.
        for _ in 0..<60 {
            try Task.checkCancellation()
            do {
                try focus()
                stableChecks += 1
                if stableChecks >= 13 { return }
            } catch {
                stableChecks = 0
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DictationFailure(message: "Could not settle focus in the original field. Your transcript is on the clipboard.")
    }

    func insert(_ transcript: String, requiresSettling: Bool = true) async throws -> Bool {
        var stage = "original-text"
        var inserted = false
        defer { Log.info("Dictation insertion pid=\(application.processIdentifier) stage=\(stage) inserted=\(inserted)") }
        let before = Self.text(in: element)
        _ = try snapshot.replacingSelection(with: transcript, currentText: before)
        stage = "restore-focus"
        try await restoreFocus(requiresSettling: requiresSettling)
        try Task.checkCancellation()
        let currentText = Self.text(in: element)
        _ = try snapshot.replacingSelection(with: transcript, currentText: currentText)
        stage = "restore-selection"
        let liveSelection = Self.selectedRange(in: element)
        let effective = DictationInsertionSnapshot.effectiveInsertionRange(
            snapshotSelection: snapshot.selection,
            snapshotText: snapshot.text,
            liveSelection: liveSelection,
            currentText: currentText)
        Log.info("Dictation caret snapshot=\(String(describing: snapshot.selection)) live=\(String(describing: liveSelection)) effective=\(String(describing: effective))")
        let expected: String?
        if let effective, let currentText {
            expected = DictationInsertionSnapshot.replacing(effective, in: currentText, with: transcript)
        } else if snapshot.selection == nil, liveSelection == nil {
            // Neither capture nor refocus exposed a cursor (and the text is unreadable):
            // paste at the app's current caret instead of forcing position 0.
            expected = nil
        } else {
            expected = try snapshot.replacingSelection(with: transcript, currentText: currentText)
        }
        if let effective {
            var range = CFRange(location: effective.location, length: effective.length)
            guard let value = AXValueCreate(.cfRange, &range) else {
                throw DictationFailure(message: "Could not restore the original cursor position.")
            }
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            guard Self.selectedRange(in: element) == effective else {
                throw DictationFailure(message: "Could not restore the original cursor position. Your transcript is ready to copy.")
            }
        }
        guard Self.text(in: element) == before else {
            throw DictationFailure(message: "The field changed during insertion. Check the text before trying again.")
        }
        try validateFocus()
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        board.clearContents()
        guard board.setString(transcript, forType: .string) else {
            board.clearContents()
            board.writeObjects(saved)
            throw DictationFailure(message: "Could not prepare the clipboard for insertion.")
        }
        let change = board.changeCount
        defer {
            // A copy made by the user during insertion takes precedence over the saved clipboard.
            if board.changeCount == change {
                board.clearContents()
                board.writeObjects(saved)
            }
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw DictationFailure(message: "Could not send Paste to the focused app.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        try Task.checkCancellation()
        try validateFocus()
        if let effective, Self.selectedRange(in: element) != effective {
            // The caret drifted while the clipboard was prepared (e.g. the target
            // app re-settled focus). Re-apply once so Paste does not land at 0.
            var range = CFRange(location: effective.location, length: effective.length)
            if let value = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            guard Self.selectedRange(in: element) == effective else {
                throw DictationFailure(message: "The cursor moved before insertion. Your transcript is ready to copy.")
            }
        }
        stage = "paste-verification"
        // Send through normal keyboard routing only after verifying the exact destination.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        inserted = try await Self.verifyPaste(before: before, expected: expected) {
            Self.text(in: element)
        }
        return inserted
    }

    static func verifyPaste(before: String?, expected: String?, readText: () -> String?) async throws -> Bool {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            let current = readText()
            if let expected, current == expected { return true }
            if current != before { return false }
        }
        return false
    }
}
