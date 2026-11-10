import QuartzCore
import Carbon.HIToolbox

/** CGEvent 탭 콜백은 self를 못 쓰므로, Caps Lock down/up 쌍을 여기 둔다. */
private var capsLockTapDown = false
private var capsLockHIDHandledAt: CFTimeInterval?
private var clearingStuckCapsLock = false

/** 원격 제어 앱이 넣은 오른쪽 ⌘·⌥의 눌림 상태. down에서 한 번만 전환한다. */
private var remoteRotateKeyDown: Set<Int64> = []

func resetCapsLockTapDown() {
    capsLockTapDown = false
    capsLockHIDHandledAt = nil
    remoteRotateKeyDown.removeAll()
}

/** HID가 먼저 처리한 Caps Lock down을 뒤늦은 CGEvent가 다시 전환하지 않게 한다. */
func markCapsLockHandledByHID() {
    capsLockHIDHandledAt = CACurrentMediaTime()
}

private func consumeCapsLockHandledByHID() -> Bool {
    guard let handledAt = capsLockHIDHandledAt else { return false }
    capsLockHIDHandledAt = nil

    // 물리 Caps Lock은 현재 환경에서 CGEvent가 HID보다 약 80ms 늦게 온다.
    return CACurrentMediaTime() - handledAt <= 0.25
}

/** 한/A용 Caps Lock이 OS 대문자 잠금으로 남는 것을 막는다. */
private func stripAndClearCapsLock(_ event: CGEvent) {
    if event.flags.contains(.maskAlphaShift) {
        var flags = event.flags
        flags.remove(.maskAlphaShift)
        event.flags = flags
        if !getKeyboardCapsLock() && !clearingStuckCapsLock {
            clearingStuckCapsLock = true
            setKeyboardCapsLock(enabled: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                clearingStuckCapsLock = false
            }
        }
    }
}

enum HotKeyMonitorError: Error, CustomStringConvertible {
    case axProcessNotTrusted
    case failedToCreateTap
    case failedToEnableTap
    case failedToCreateSource
    case failedToInstall(OSStatus)
    case failedToRegister(OSStatus)

    var description: String {
        switch self {
        case .axProcessNotTrusted:
            "손쉬운 사용 권한을 허용해 주세요."
        case .failedToCreateTap:
            "알 수 없는 오류가 발생했습니다. (tapCreate)"
        case .failedToEnableTap:
            "알 수 없는 오류가 발생했습니다. (tapEnable)"
        case .failedToCreateSource:
            "알 수 없는 오류가 발생했습니다. (source)"
        case .failedToInstall(let err):
            "알 수 없는 오류가 발생했습니다. (install, \(err))"
        case .failedToRegister(let err):
            "알 수 없는 오류가 발생했습니다. (register, \(err))"
        }
    }
}

/**
 단축키 모니터링 및 사용자의 한/A 전환키 조합을 시스템에 등록
 - ``ClickMonitor``
 */
class HotKeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isTapEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private var eventHandlerRef: EventHandlerRef?
    private var eventHotKeyRefs: [EventHotKeyRef] = []

    func start() throws {
        debug()

        try startCGEvent()
        try startCarbonEvent()
    }

    private func startCGEvent() throws {
        debug()

        if tap != nil || source != nil {
            warning("초기화된 tap 또는 source가 이미 있음")
            return
        }

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(
                1 << CGEventType.keyDown.rawValue
                | 1 << CGEventType.flagsChanged.rawValue
            ),
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    appDelegate()?.restartMonitors(nil)
                    return Unmanaged.passUnretained(event)
                }

                guard !(appDelegate()?.isSecureInputEnabledInFrontmostApp() ?? true) else {
                    resetCapsLockTapDown()
                    appDelegate()?.inputMonitor.cancelCapsLockHoldTimer()
                    return Unmanaged.passUnretained(event)
                }
                guard isSokIMCurrentInputSource() else {
                    resetCapsLockTapDown()
                    appDelegate()?.inputMonitor.cancelCapsLockHoldTimer()
                    if Preferences.gameInputRecovery && type == .keyDown {
                        appDelegate()?.scheduleRawKoreanIMERecover()
                    }
                    return Unmanaged.passUnretained(event)
                }

                debug("\(type) \(event.flags)")
                // 속 입력기에서만 Caps Lock을 한/A 키로 사용한다.
                if Preferences.rotateShortcuts.contains(.capsLock) {
                    stripAndClearCapsLock(event)
                }

                let keycode = event.getIntegerValueField(.keyboardEventKeycode)
                if Preferences.rotateShortcuts.contains(.capsLock)
                    && keycode == Int64(kVK_CapsLock) {
                    // Caps Lock down/up이 쌍으로 온다. 한/A는 down에서만 전환하고, OS 대소문자는 흡수한다.
                    if !capsLockTapDown {
                        capsLockTapDown = true
                        if consumeCapsLockHandledByHID() {
                            notice("Caps Lock down → HID already handled")
                        } else {
                            notice("Caps Lock down → 한/A")
                            appDelegate()?.rotateFromShortcut()
                        }
                        setKeyboardCapsLock(enabled: false)
                    } else {
                        capsLockTapDown = false
                        notice("Caps Lock up")
                        appDelegate()?.inputMonitor.cancelCapsLockHoldTimer()
                    }
                    return nil
                }


                let flags = Int32(event.flags.rawValue)
                let isRightCommand = (flags & NX_COMMANDMASK != 0) && (flags & NX_DEVICERCMDKEYMASK != 0)
                let isRightOption = (flags & NX_ALTERNATEMASK != 0) && (flags & NX_DEVICERALTKEYMASK != 0)
                debug("isRightCommand: \(isRightCommand), isRightOption: \(isRightOption)")

                // 원격 제어 앱(StarDesk 등)은 키를 CGEventPost로 넣어서 HID 입력 모니터에 안 잡힌다.
                // 하드웨어 키는 sourcePID가 0이고, 원격 앱이 넣은 키는 그 앱의 pid가 실린다.
                let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
                let isRemote = sourcePID != 0 && sourcePID != Int64(getpid())
                let remoteRightOptionIsRotate = isRemote
                    && (Preferences.remoteRightOption || Preferences.rotateShortcuts.contains(.rightOption))
                let remoteRightCommandIsRotate = isRemote && Preferences.rotateShortcuts.contains(.rightCommand)

                // 원격 키업은 전송 프로세스나 설정이 바뀌어도 기록을 해제한다.
                if type == .flagsChanged && (keycode == Int64(kVK_RightOption) || keycode == Int64(kVK_RightCommand)) {
                    let isDown = keycode == Int64(kVK_RightOption) ? isRightOption : isRightCommand
                    if !isDown {
                        remoteRotateKeyDown.remove(keycode)
                    } else if (keycode == Int64(kVK_RightOption) && remoteRightOptionIsRotate)
                        || (keycode == Int64(kVK_RightCommand) && remoteRightCommandIsRotate) {
                        if remoteRotateKeyDown.insert(keycode).inserted {
                            notice("원격 키 \(keycode) down → 한/A (pid \(sourcePID))")
                            appDelegate()?.rotateFromShortcut()
                        }
                    }
                }

                let stripRightCommand = Preferences.rotateShortcuts.contains(.rightCommand) && isRightCommand
                let stripRightOption = (Preferences.rotateShortcuts.contains(.rightOption)
                    || remoteRightOptionIsRotate || remoteRotateKeyDown.contains(Int64(kVK_RightOption)))
                    && isRightOption

                // 전환키 자체만 숨긴다. 다른 modifier의 변화는 modifier만 정리해 전달한다.
                if type == .flagsChanged
                    && ((keycode == Int64(kVK_RightCommand) && stripRightCommand)
                        || (keycode == Int64(kVK_RightOption) && stripRightOption)) {
                    return nil
                }

                // 한/A 키를 떼기 전에 다음 글자가 눌린 경우: 버리지 않고 한/A 키 modifier만 빼서 글자로 보낸다.
                // 단축키로는 쓰이지 않으므로 의도하지 않은 단축키 실행(#5)도 여전히 막힌다.
                if stripRightCommand || stripRightOption {
                    var stripped = event.flags.rawValue
                    if stripRightCommand {
                        stripped &= ~UInt64(NX_DEVICERCMDKEYMASK)
                        if stripped & UInt64(NX_DEVICELCMDKEYMASK) == 0 {
                            stripped &= ~UInt64(NX_COMMANDMASK)
                        }
                    }
                    if stripRightOption {
                        stripped &= ~UInt64(NX_DEVICERALTKEYMASK)
                        if stripped & UInt64(NX_DEVICELALTKEYMASK) == 0 {
                            stripped &= ~UInt64(NX_ALTERNATEMASK)
                        }
                    }
                    event.flags = CGEventFlags(rawValue: stripped)
                    debug("한/A 키 modifier 제거 후 통과")
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        guard let tap else {
            warning("CGEvent.tapCreate 실패")
            if AXIsProcessTrusted() {
                throw HotKeyMonitorError.failedToCreateTap
            } else {
                throw HotKeyMonitorError.axProcessNotTrusted
            }
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source else {
            warning("CFMachPortCreateRunLoopSource 실패")
            throw HotKeyMonitorError.failedToCreateSource
        }
        self.source = source

        // 메뉴가 열린 동안(eventTracking)에도 탭이 돌아야 키 입력이 멈추지 않음
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if !CGEvent.tapIsEnabled(tap: tap) {
            warning("CGEvent.tapEnable 실패")
            throw HotKeyMonitorError.failedToEnableTap
        }

        debug("CGEvent.tapEnable 성공")
    }

    private func startCarbonEvent() throws {
        debug()

        if eventHandlerRef != nil || eventHotKeyRefs.count > 0 {
            warning("초기화된 eventHandlerRef 또는 eventHotKeyRef가 이미 있음")
            return
        }

        /** eventHandlerRef */

        var eventHandlerRef: EventHandlerRef?
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let err1 = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                debug()
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
        debug("InstallEventHandler 성공")
        if err1 != 0 {
            warning("InstallEventHandler 실패: \(err1)")
            throw HotKeyMonitorError.failedToInstall(err1)
        }
        self.eventHandlerRef = eventHandlerRef

        /** eventHotKeyRef */

        try Preferences.rotateShortcuts.forEach {
            var eventHotKeyRef: EventHotKeyRef?
            let code: UInt32
            let modifiers: UInt32

            switch $0 {
            case .capsLock:
                debug("HotKey 해당 없음")
                return
            case .rightCommand:
                debug("HotKey 해당 없음")
                return
            case .rightOption:
                debug("HotKey 해당 없음")
                return
            case .commandSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(cmdKey)
            case .shiftSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(shiftKey)
            case .controlSpace:
                code = UInt32(kVK_Space)
                modifiers = UInt32(controlKey)
            }

            let err2 = RegisterEventHotKey(
                code,
                modifiers,
                EventHotKeyID(signature: 0, id: 0),
                GetApplicationEventTarget(),
                0,
                &eventHotKeyRef
            )
            debug("RegisterEventHotKey 성공: \($0)")
            if err2 != 0 {
                warning("RegisterEventHotKey 실패: \(err2)")
                throw HotKeyMonitorError.failedToRegister(err2)
            }
            eventHotKeyRefs.append(eventHotKeyRef!)
        }
    }

    func stop() {
        stopCGEvent()
        stopCarbonEvent()
    }

    private func stopCGEvent() {
        debug()
        resetCapsLockTapDown()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        } else {
            notice("초기화된 tap이 없음")
        }

        if let source {
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        } else {
            notice("초기화된 source가 없음")
        }
    }

    private func stopCarbonEvent() {
        debug()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            debug("RemoveEventHandler 성공")
            self.eventHandlerRef = nil
        } else {
            notice("초기화된 eventHandlerRef가 없음")
        }

        if eventHotKeyRefs.count > 0 {
            eventHotKeyRefs.forEach {
                UnregisterEventHotKey($0)
                debug("UnregisterEventHotKey 성공")
            }
            eventHotKeyRefs = []
        } else {
            notice("초기화된 eventHotKeyRef가 없음")
        }
    }
}
