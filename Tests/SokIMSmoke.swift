import AppKit
import Carbon.HIToolbox

// Run with the production Engine, Preferences and State sources; no input monitors are started.
final class TestStatusBar {
    func setEngine(_ engine: Engine.Type) {}
}

final class TestAppDelegate {
    var inputEngine: Engine.Type = TwoSetEngine.self
    let statusBar = TestStatusBar()
    func restartMonitors(_ notification: Notification?) {}
}

private let testAppDelegate = TestAppDelegate()
func appDelegate() -> TestAppDelegate? { testAppDelegate }
func debug(_ message: @autoclosure () -> String = "") {}
private var testCapsLock = false
func getKeyboardCapsLock() -> Bool { testCapsLock }
func flip<T: Hashable>(_ array: [T]) -> [T: Int] {
    Dictionary(uniqueKeysWithValues: zip(array, 0..<array.count))
}
func flip<T: Hashable, U: Hashable>(_ dictionary: [T: U]) -> [U: T] {
    dictionary.reduce(into: [:]) { $0[$1.value] = $1.key }
}

enum InputType: String {
    case keyDown, keyUp
}

struct Input: CustomStringConvertible {
    let type: InputType
    let usage: UInt32
    var description: String { "\(type):\(usage)" }
}

@main
private enum SokIMSmoke {
    static func main() {
        UserDefaults.standard.setVolatileDomain(
            ["RotateShortcuts": ["CapsLock", "RightCommand", "F18", "KeyCode:79"], "GraveOverWon": true],
            forName: UserDefaults.argumentDomain
        )

        precondition(!shouldBlockSecureInput(false, ownerPID: nil, frontmostPID: 100))
        precondition(shouldBlockSecureInput(true, ownerPID: 100, frontmostPID: 100))
        precondition(!shouldBlockSecureInput(true, ownerPID: 200, frontmostPID: 100))
        precondition(shouldBlockSecureInput(true, ownerPID: nil, frontmostPID: 100))
        precondition(shouldBlockSecureInput(true, ownerPID: 0, frontmostPID: 100))
        precondition(shouldBlockSecureInput(true, ownerPID: 100, frontmostPID: nil))
        precondition(shouldBlockSecureInput(false, ownerPID: nil, frontmostPID: nil))

        precondition(Preferences.rotateKeys.contains(.shortcut(.capsLock)))
        precondition(Preferences.rotateKeys.contains(.shortcut(.rightCommand)))
        precondition(Preferences.rotateKeys.contains(.keyCode(kVK_F18)))
        precondition(Preferences.rotateKeys.filter { $0 == .keyCode(kVK_F18) }.count == 1)
        precondition(RotateKey.keyCode(kVK_F18).rawValue == "KeyCode:79")
        precondition(RotateKey(rawValue: "KeyCode:79") == .keyCode(kVK_F18))
        precondition(RotateKey(rawValue: "KeyCode:not-a-number") == nil)
        let grave = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "`", charactersIgnoringModifiers: "`",
                                    isARepeat: false, keyCode: UInt16(kVK_ANSI_Grave))!
        precondition(TwoSetEngine.eventToTuple(grave)?.char == "`", "원화 대신 백틱 설정이 적용되지 않음")
        let letter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "a", charactersIgnoringModifiers: "a",
                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_A))!
        testCapsLock = true
        precondition(QwertyEngine.eventToTuple(letter)?.char == "A", "Caps Lock 유지 시 대문자가 입력되지 않음")
        testCapsLock = false
        precondition(QwertyEngine.eventToTuple(letter)?.char == "a", "Caps Lock 해제 후 소문자가 입력되지 않음")

        var state = State(engine: TwoSetEngine.self)
        state.rotateFromShortcut()
        precondition(state.engine == QwertyEngine.self)
        state.next(Input(type: .keyDown, usage: ModifierUsage.rightCommand.rawValue))
        state.next(Input(type: .keyDown, usage: 0x04))
        precondition(state.composed == "a", "Right Command 전환 직후 글자가 누락됨")

        state.clear(composed: true, composing: true)
        state.rotateFromKeyCode()
        precondition(state.engine == TwoSetEngine.self, "단축키 직후 F18 전환이 누락됨")
        for usage: UInt32 in [0x0A, 0x0E, 0x16] {
            let tuple = TwoSetEngine.usageToTuple(usage, false, false, false)!
            state.next(tuple)
        }
        precondition(state.composing == "한", "한글 조합이 올바르게 유지되지 않음")

        var commandState = State(engine: QwertyEngine.self)
        commandState.next(Input(type: .keyDown, usage: ModifierUsage.leftCommand.rawValue))
        commandState.next(Input(type: .keyDown, usage: 0x04))
        precondition(commandState.composed.isEmpty, "일반 Command 단축키가 문자로 입력됨")
        commandState.resetInputState()
        commandState.next(Input(type: .keyDown, usage: 0x04))
        precondition(commandState.composed == "a", "모니터 재시작 후 Command 상태가 남음")
        print("SokIM 입력 설정·전환·한글 조합 검사 통과")
    }
}
