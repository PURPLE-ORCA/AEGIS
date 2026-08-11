import Carbon
import Foundation

@MainActor
final class GlobalPushToTalkHotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private(set) var isRegistered = false

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }

    @discardableResult
    func register() -> Bool {
        guard !isRegistered else { return true }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
        guard handlerStatus == noErr else { return false }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registerStatus == noErr else {
            if let eventHandlerReference {
                RemoveEventHandler(eventHandlerReference)
                self.eventHandlerReference = nil
            }
            return false
        }

        isRegistered = true
        return true
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
        isRegistered = false
    }

    private static let signature: OSType = 0x43414953 // "CAIS"

    private static let eventHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == GlobalPushToTalkHotKey.signature,
              identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }

        let monitor = Unmanaged<GlobalPushToTalkHotKey>.fromOpaque(context).takeUnretainedValue()
        let kind = GetEventKind(event)
        DispatchQueue.main.async {
            if kind == UInt32(kEventHotKeyPressed) {
                monitor.onPress?()
            } else if kind == UInt32(kEventHotKeyReleased) {
                monitor.onRelease?()
            }
        }
        return noErr
    }
}
