import OSLog

enum AutoPauseNormalizer {
    @MainActor
    static func normalize(
        currentMinutes: UInt16,
        desiredMinutes: UInt16 = 0,
        logger: Logger? = nil,
        setMinutes: @escaping (UInt16) async -> Void
    ) async {
        guard currentMinutes != desiredMinutes else {
            DeveloperMode.debugPrint(.syncAuto, "Auto-pause OK: device=\(currentMinutes)m matches expected=\(desiredMinutes)m")
            return
        }
        logger?.notice("Auto-pause \(currentMinutes)m detected; setting to \(desiredMinutes)m")
        DeveloperMode.debugPrint(.syncAuto, "Auto-pause MISMATCH: device=\(currentMinutes)m expected=\(desiredMinutes)m; applying")
        await setMinutes(desiredMinutes)
    }
}
