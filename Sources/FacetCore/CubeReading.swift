/// The cube as it stands, asked at the moment something is about to be drawn or decided from it.
///
/// Three answers rather than one because they fail differently: there may be no cube at all, there may be a cube
/// nobody has asked yet, and a cube that has answered may be locked, which changes what its pause byte means.
///
/// **Moved out of `MenuBarController` on 2026-09-10 and into the core**, where it always belonged: it names three
/// core states and holds no platform anything. `StatusItemMenu` and `StatusItemTitle` are both decided from it,
/// and both are core, so a Mac type would have been the tail wagging the dog.
package struct CubeReading: Equatable {
    package let isCubeConnected: Bool

    /// `nil` when the cube has not been asked, or would not answer. See `CubeLockRules.title`.
    package let cubeLockState: CubeLockState

    /// `nil` for the same two reasons. **Only meaningful while the cube is unlocked**, since a locked cube
    /// reports itself paused whatever its pause byte says -- which is why `PauseMenuRules` reads it in the one
    /// case where the cube is known not to be locked, and nowhere else.
    package let cubePauseState: CubePauseState

    /// Written out so `cubePauseState` can default to "nobody asked", which is what a reading built without it
    /// means. The alternative was making every existing caller name a fact it has no opinion about, which reads
    /// as an assertion that the cube is running rather than as silence.
    package init(
        isCubeConnected: Bool,
        cubeLockState: CubeLockState,
        cubePauseState: CubePauseState = .unknown
    ) {
        self.isCubeConnected = isCubeConnected
        self.cubeLockState = cubeLockState
        self.cubePauseState = cubePauseState
    }
}
