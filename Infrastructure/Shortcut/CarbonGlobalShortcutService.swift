import Carbon.HIToolbox

enum GlobalShortcutError: LocalizedError {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallationFailed(let status):
            return "无法安装全局快捷键事件处理器（\(status)）"
        case .registrationFailed(let status):
            return "无法注册全局快捷键（\(status)）"
        }
    }
}

@MainActor
final class CarbonGlobalShortcutService: GlobalShortcutHandling {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<CarbonGlobalShortcutService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                service.handler?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            self.handler = nil
            throw GlobalShortcutError.eventHandlerInstallationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: 0x41504C53, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            unregister()
            throw GlobalShortcutError.registrationFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        handler = nil
    }

    isolated deinit {
        unregister()
    }
}
