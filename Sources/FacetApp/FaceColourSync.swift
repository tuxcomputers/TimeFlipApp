import AppKit

/// Telling the cube what colour to light each face.
///
/// **One place that knows the order and the pace**, for `CubeLock`'s reason: several things change what a face should
/// be lit in -- a link coming up, a face taking a category, a category being recoloured or retired, and the cube
/// asking outright -- and each of them written separately would be several answers to one question.
///
/// **Nothing is remembered about what the cube is showing.** `0x11` has no read-back in the vendor spec, so the only
/// possible record is what was last sent, and this deliberately does not keep one: a link coming up sends all twelve
/// outright rather than trusting a note the app wrote to itself. The archive kept `lastSentFaceColors` and wrote only
/// what had drifted from it, which saves eleven writes on a reconnect and costs the thing `CLAUDE.md`'s first rule is
/// about -- a second copy of a fact that nothing can check, going stale the first time a cube is coloured by anything
/// else. Twelve writes on a connect is what the archive itself did on the first connect of every run.
///
/// **What is kept instead is a queue**, and it is not a cache: `DeviceLogin.send` refuses a command while one is
/// still out, so twelve faces have to go one after another, and an edit arriving mid-run has to wait its turn rather
/// than be dropped. The colour of each face is read at the moment its own command is built, not when the run started,
/// so a queue waiting its turn cannot carry a stale colour.
@MainActor
final class FaceColourSync {
    /// Sends one command and reports whether the cube took it. `BluetoothRadio.send`, handed in rather than held, so
    /// the whole sequence can be driven in a test with no radio -- `CubeLock`'s arrangement, for its reason.
    private let send: (Data, @escaping (Bool) -> Void) -> Void

    /// Whether there is a live link to send anything down.
    private let isCubeConnected: () -> Bool

    /// What one face should be lit in, **read from the tables at the moment the command is built**.
    ///
    /// A closure rather than the stores themselves, so this knows nothing about how a face becomes a colour: that is
    /// two reads and a fallback, and where they live is `main.swift`'s business.
    private let faceColour: (Int) -> FaceColour

    private let debugLog: DebugLog?

    /// How long after answering the cube to ignore it asking again.
    ///
    /// **The archive's number, and it was bought with a real failure.** A cube that has lost its colours says so on
    /// every notification, on every re-read and on every reconnect, and each answer is twelve flash writes that also
    /// light the LED. Answering one for one turned 8 requests in one second into 96 colour writes, which lit the LED
    /// continuously and helped brown out a device that was already failing to hold its own settings. So the requests
    /// are collapsed into one answer and the next half-minute of asking is counted rather than obeyed.
    static let cooldownSeconds: TimeInterval = 30

    /// The faces still to send, and why each was queued.
    ///
    /// **Never two entries for one face**: the colour is read when the command is built, so a second entry would send
    /// the same colour twice and cost a flash write and an LED flash for nothing.
    ///
    /// **The face whose command is already out is not in here**, and that is what makes the last edit win. It was
    /// removed when its command was written, so a face recoloured while its own command is in flight is queued afresh
    /// rather than taken for a duplicate -- which is right, since the command on the wire is carrying the colour from
    /// before the edit.
    private var queue: [(face: Int, reason: String)] = []
    private var isSending = false

    /// The cube's repeated asking, collapsed. See `cooldownSeconds`.
    private var answeredTheCubeAt: Date?
    private var suppressedRequests = 0

    /// Whether the login has finished asking the cube its own questions, so the command channel is free.
    ///
    /// **Measured, not assumed: this cube asks for its colours before that point, every time.** The systemState read
    /// the login makes is answered `02 02 00 00` about 480ms before the login's last question comes back -- and the
    /// `0x17` read still outstanding at that moment does not set `isCommandInFlight`, so nothing downstream would
    /// have refused a colour command written over the top of it. 26 connects in `debug.sqlite` on 2026-08-28, all
    /// with the same shape.
    private var isLinkSettled = false

    /// What `isCubeConnected` said when the last opening send went out.
    ///
    /// **The opening send is gated on this changing to true, rather than on being told a login settled.** A callback
    /// is an event and can arrive twice; the connection is a state, and "the cube is now connected and it was not
    /// before" is the thing that actually means there is a cube to colour. Kept as one bool rather than read twice,
    /// because a transition is the one question a single read cannot answer.
    private var wasCubeConnected = false

    init(
        send: @escaping (Data, @escaping (Bool) -> Void) -> Void,
        isCubeConnected: @escaping () -> Bool,
        faceColour: @escaping (Int) -> FaceColour,
        debugLog: DebugLog?
    ) {
        self.send = send
        self.isCubeConnected = isCubeConnected
        self.faceColour = faceColour
        self.debugLog = debugLog
    }

    /// Every face, in order.
    func sendAll(because reason: String) {
        send(faces: Array(FaceColourRules.faces), because: reason)
    }

    /// The login has finished asking the cube its own questions. Sends all twelve, if this is a cube that has just
    /// become connected.
    ///
    /// **Two conditions, and they are different questions.** `isCubeConnected` changing to true is *whether* there is
    /// a cube to colour; the login settling is *when* it is safe to say anything to it. Either on its own sends at
    /// the wrong moment: the connection turns true several round trips before the command channel is free, and this
    /// callback says nothing about whether the cube it refers to is still there.
    ///
    /// **The transition is what is gated on, not the state.** A cube still connected from the last send has already
    /// been coloured, so a second settling on one connection sends nothing -- which is what stops a callback that
    /// fires twice from costing twelve flash writes.
    ///
    /// **It also answers a request the cube made while the login was still talking**, which on this hardware is every
    /// request there has ever been. Nothing extra goes out for it: all twelve are going anyway, which is the whole of
    /// what the cube asked for.
    func linkSettled() {
        isLinkSettled = true
        let isConnected = isCubeConnected()
        guard isConnected, !wasCubeConnected else {
            debugLog?.record(
                .colour,
                isConnected
                    ? "The login settled again on a cube already coloured on this connection, so nothing is sent"
                    : "The login settled on a cube that is no longer connected, so there is nothing to colour"
            )
            return
        }
        wasCubeConnected = true
        let wasAsked = suppressedRequests > 0
        if wasAsked {
            suppressedRequests = 0
            answeredTheCubeAt = Date()
        }
        sendAll(because: wasAsked ? "the cube connected, having asked for them" : "the cube connected")
    }

    /// One face, which is what an edit changes.
    ///
    /// **A face the cube does not have is not an error here**, it is manual mode: face 13 is the app's own, and the
    /// paths that assign a category reach both. Saying so out loud rather than silently skipping, since a colour that
    /// never went anywhere is otherwise indistinguishable from one that did.
    func send(face: Int, because reason: String) {
        guard FaceColourRules.faces.contains(face) else {
            debugLog?.record(.colour, "Face \(face) is not one the cube has, so there is no colour to send it")
            return
        }
        send(faces: [face], because: reason)
    }

    /// Several faces, which is what recolouring or retiring a category changes.
    func send(faces wanted: [Int], because reason: String) {
        guard isCubeConnected() else {
            // Not deferred and not remembered: the next link coming up sends all twelve anyway, so there is nothing
            // for this to leave behind. Said out loud, because an edit that lit nothing is worth a row.
            debugLog?.record(.colour, "No cube connected, so \(reason) lights nothing")
            return
        }
        for face in wanted where FaceColourRules.faces.contains(face) && !queue.contains(where: { $0.face == face }) {
            queue.append((face: face, reason: reason))
        }
        run()
    }

    /// The cube saying it has lost its face colours (system state `0x0202`,
    /// `DeviceSystemStateRules.Sync.faceColoursRequired`).
    ///
    /// Collapsed rather than answered one for one. See `cooldownSeconds` for what that cost when it was not.
    func cubeAskedForThem() {
        // **Asked before the login has finished its own questions**, which is when this cube always asks. Counted
        // rather than answered: sending now would write over an exchange already out (see `isLinkSettled`), and
        // `linkSettled` is a moment away and sends all twelve regardless.
        guard isLinkSettled else {
            debugLog?.record(
                .colour,
                "The cube asked for its colours while the login was still talking, so the link coming up answers it"
            )
            suppressedRequests += 1
            return
        }
        if let answered = answeredTheCubeAt, Date().timeIntervalSince(answered) < Self.cooldownSeconds {
            suppressedRequests += 1
            return
        }
        if isSending {
            suppressedRequests += 1
            return
        }
        if suppressedRequests > 0 {
            debugLog?.record(.colour, "Collapsed \(suppressedRequests) repeat requests from the cube into this one")
            suppressedRequests = 0
        }
        answeredTheCubeAt = Date()
        sendAll(because: "the cube asked for its colours")
    }

    /// The link went. Drops whatever was still queued for a cube that is no longer there.
    ///
    /// **Not left to fail one command at a time.** Each queued face would be sent, refused, logged and followed by
    /// the next, which is a dozen rows saying the cube is gone where one says it once. The cooldown is cleared with
    /// it: a new connection gets a fresh hearing, the cooldown being there to stop one connection's repeated asking
    /// from being re-answered rather than to gag a cube that comes back having really lost its colours.
    func linkEnded() {
        if !queue.isEmpty {
            debugLog?.record(.colour, "The link went, so \(queue.count) face colours still to send are dropped")
            queue.removeAll()
        }
        answeredTheCubeAt = nil
        suppressedRequests = 0
        isLinkSettled = false
        // What makes the next connection a change to true rather than more of this one.
        wasCubeConnected = false
    }

    private func run() {
        guard !isSending else { return }
        guard !queue.isEmpty else { return }
        isSending = true
        step()
    }

    /// One face, then whatever is behind it.
    ///
    /// **The colour is read here**, at the moment this face's command is built, which is `CLAUDE.md`'s rule read
    /// literally: a face queued a second ago whose category has changed since goes out as what it is now.
    private func step() {
        guard let next = queue.first else {
            isSending = false
            return
        }
        queue.removeFirst()
        let wanted = faceColour(next.face)
        let described = FaceColourRules.describe(wanted)
        send(FaceColourRules.command(for: wanted)) { [weak self] acknowledged in
            guard let self else { return }
            // **Acknowledged, not confirmed**, and the word is chosen: `0x11` has no read-back at all, so what this
            // says is that the cube took the bytes. Whether the LED changed is not a question the protocol answers.
            self.debugLog?.record(
                .colour,
                acknowledged
                    ? "The cube took \(described) (\(next.reason)), with no read-back to confirm it"
                    : "The cube would not take \(described) (\(next.reason))"
            )
            self.step()
        }
    }
}
