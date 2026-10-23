import Carbon.HIToolbox

enum GlobalShortcutError: LocalizedError {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallationFailed(let status):
            String(localized: "无法安装全局快捷键事件处理器（\(Int(status))）")
        case .registrationFailed(let status) where status == eventHotKeyExistsErr:
            String(localized: "该快捷键已被其他应用占用，请换一个组合")
        case .registrationFailed(let status):
            String(localized: "无法注册全局快捷键（\(Int(status))）")
        }
    }
}

/// 每个实例注册一个全局热键。同一进程内所有实例的事件处理器都会收到任一热键的按下事件，
/// 因此各实例使用不同的热键 ID，只认领自己的那一个。
@MainActor
final class CarbonGlobalShortcutService: GlobalShortcutHandling {
    private let hotKeyIdentifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    init(hotKeyIdentifier: UInt32 = 1) {
        self.hotKeyIdentifier = hotKeyIdentifier
    }

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressedHotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedHotKeyID
                )
                let pressedID = pressedHotKeyID.id
                let service = Unmanaged<CarbonGlobalShortcutService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // 热键事件经应用事件目标由主运行循环派发，回调总在主线程。
                return MainActor.assumeIsolated {
                    // 其他实例的热键交还给下一个处理器。
                    guard status == noErr, pressedID == service.hotKeyIdentifier else {
                        return OSStatus(eventNotHandledErr)
                    }
                    service.handler?()
                    return noErr
                }
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

        // 签名为四字符码 'APLS'，与热键 ID 一起标识本应用注册的热键。
        let hotKeyID = EventHotKeyID(signature: 0x41504C53, id: hotKeyIdentifier)
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
