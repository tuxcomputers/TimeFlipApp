import OSLog

enum AutoPauseNormalizer {
    @MainActor
    static func normalize(
        currentMinutes: UInt16,
        desiredMinutes: UInt16 = 0,
        logger: Logger? = nil,
        setMinutes: @escaping (UInt16) async -> Void
    ) async {
        guard currentMinutes != desiredMinutes else { return }
        logger?.notice("Auto-pause \(currentMinutes)m detected; setting to \(desiredMinutes)m")
        await setMinutes(desiredMinutes)
    }
}
