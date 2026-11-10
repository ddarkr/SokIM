import Darwin

/** 전면 앱을 확인할 수 없거나 보안 입력의 소유자를 모르면 OS에 입력을 맡긴다. */
func shouldBlockSecureInput(_ enabled: Bool, ownerPID: pid_t?, frontmostPID: pid_t?) -> Bool {
    guard let frontmostPID, frontmostPID > 0 else { return true }
    guard enabled else { return false }
    guard let ownerPID, ownerPID > 0 else { return true }
    return ownerPID == frontmostPID
}
