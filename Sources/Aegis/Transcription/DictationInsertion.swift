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
        return (text as NSString).replacingCharacters(in: selection, with: transcript)
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
        let expected = try snapshot.replacingSelection(with: transcript, currentText: before)
        stage = "restore-focus"
        try await restoreFocus(requiresSettling: requiresSettling)
        try Task.checkCancellation()
        let currentText = Self.text(in: element)
        _ = try snapshot.replacingSelection(with: transcript, currentText: currentText)
        stage = "restore-selection"
        if let selection = snapshot.selection {
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range) else {
                throw DictationFailure(message: "Could not restore the original cursor position.")
            }
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            guard Self.selectedRange(in: element) == snapshot.selection else {
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
