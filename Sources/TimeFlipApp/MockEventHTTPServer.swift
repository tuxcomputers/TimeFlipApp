import Foundation
import Network
import OSLog

final class MockEventHTTPServer: @unchecked Sendable {
    private enum Constants {
        static let defaultPort: UInt16 = 8_765
        static let receiveMinimumLength: Int = 1
        static let receiveMaximumLength: Int = 2_048
        static let requestLineMinimumParts: Int = 2
        static let loopbackIPv4 = Data([127, 0, 0, 1])
        static let loopbackIPv6 = Data(repeating: 0, count: 15) + Data([1])
        static let helpFacetExample: UInt8 = 3
        static let helpAutoPauseMinutesExample: UInt16 = 5
        static let helpBatteryExample: UInt8 = 90
        static let helpEpochExample: TimeInterval = 1_700_000_000
    }

    private let port: NWEndpoint.Port
    private let controller: TimeFlipMockControlling
    private let logger: Logger
    private let queue = DispatchQueue(label: "com.timeflip.mock-http")
    private var listener: NWListener?

    init(
        controller: TimeFlipMockControlling,
        port: UInt16 = Constants.defaultPort,
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "mock-http")
    ) {
        let resolvedPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Constants.defaultPort)
        guard let resolvedPort else {
            fatalError("Invalid mock HTTP port configuration")
        }
        self.port = resolvedPort
        self.controller = controller
        self.logger = logger
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Belt-and-suspenders alongside the application-layer loopback check in route(_:):
            // this restricts the actual socket bind to loopback, so nothing external can even
            // open a connection in the first place.
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.logger.debug("Mock HTTP listener state: \(String(describing: state), privacy: .public)")
            }
            listener.start(queue: queue)
            self.listener = listener
            logger.notice("Mock HTTP listener started on http://127.0.0.1:\(self.port.rawValue, privacy: .public)")
        } catch {
            logger.error("Failed to start mock HTTP listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        logger.notice("Mock HTTP listener stopped")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Single receive of at most receiveMaximumLength bytes: a request split
        // across TCP segments (or larger than the cap) misparses to 400.
        // Fine for the curl-driven mock this serves.
        connection.receive(
            minimumIncompleteLength: Constants.receiveMinimumLength,
            maximumLength: Constants.receiveMaximumLength
        ) { [weak self] data, _, _, _ in
            guard let self else { return }
            Task {
                let response: Response
                if let data, let request = String(data: data, encoding: .utf8) {
                    response = await self.route(request: request, connection: connection)
                } else {
                    response = .badRequest("invalid request encoding")
                }
                self.send(response: response, on: connection)
            }
        }
    }

    private func route(request: String, connection: NWConnection) async -> Response {
        guard connectionIsLoopback(connection) else {
            return .forbidden("loopback only")
        }
        guard let line = request.split(separator: "\r\n").first else {
            return .badRequest("missing request line")
        }
        let parts = line.split(separator: " ")
        guard parts.count >= Constants.requestLineMinimumParts else {
            return .badRequest("invalid request line")
        }
        let method = parts[0]
        let target = String(parts[1])
        guard method == "GET" else {
            return .badRequest("only GET supported")
        }

        let (path, query) = splitTarget(target)
        let params = parseQuery(query)
        return await dispatch(path: path, params: params)
    }

    private func dispatch(path: String, params: [String: String]) async -> Response {
        switch path {
        case "/", "/help":
            return .ok(helpText)
        case "/status":
            return await handleStatus()
        case "/flip":
            return handleFlip(params: params)
        case "/double-tap":
            return handleDoubleTap(params: params)
        case "/pause":
            return handlePause(params: params)
        case "/lock":
            return handleLock(params: params)
        case "/auto-pause":
            return handleAutoPause(params: params)
        case "/battery":
            return handleBattery(params: params)
        case "/system":
            return handleSystem(params: params)
        case "/time":
            return handleTime(params: params)
        case "/event-log":
            return handleEventLog(params: params)
        case "/history/last":
            return await handleLastHistory()
        default:
            return .notFound("unknown path")
        }
    }

    private func send(response: Response, on connection: NWConnection) {
        let payload = response.payload
        let headers = [
            "HTTP/1.1 \(response.code) \(response.reason)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(payload.utf8.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        let buffer = headers + payload
        connection.send(content: buffer.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func splitTarget(_ target: String) -> (String, String) {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return (parts[0], parts[1])
        }
        return (parts[0], "")
    }

    private func parseQuery(_ query: String) -> [String: String] {
        guard !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts.first?.removingPercentEncoding ?? ""
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? "") : ""
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private func parseUInt8(_ value: String?) -> UInt8? {
        guard let value else { return nil }
        if let intValue = UInt8(value) {
            return intValue
        }
        if let parsed = parseHex(value), parsed <= UInt8.max {
            return UInt8(parsed)
        }
        return nil
    }

    private func parseUInt16(_ value: String?) -> UInt16? {
        guard let value else { return nil }
        if let intValue = UInt16(value) {
            return intValue
        }
        if let parsed = parseHex(value), parsed <= UInt16.max {
            return UInt16(parsed)
        }
        return nil
    }

    private func parseDouble(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let doubleValue = Double(value) {
            return doubleValue
        }
        if let parsed = parseHex(value) {
            return Double(parsed)
        }
        return nil
    }

    private func performOnMain(_ action: @MainActor @escaping () -> Void) {
        Task { @MainActor in
            action()
        }
    }

    private func snapshotAsync() async -> TimeFlipDeviceSnapshot {
        await MainActor.run { controller.snapshot() }
    }

    private func lastEventNumberAsync() async -> UInt32? {
        await MainActor.run { controller.lastEventNumber }
    }

    private func parseHex(_ value: String) -> UInt64? {
        let trimmed = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(trimmed, radix: 16)
    }

    // swiftlint:disable:next discouraged_optional_boolean
    private func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parseFacetID(_ value: String?) -> UInt8? {
        guard let parsed = parseUInt8(value) else { return nil }
        return TimeFlipConstants.isValidFacetID(parsed) ? parsed : nil
    }

    private func parseBatteryLevel(_ value: String?) -> UInt8? {
        guard let parsed = parseUInt8(value) else { return nil }
        guard parsed >= TimeFlipConstants.minBatteryLevel, parsed <= TimeFlipConstants.maxBatteryLevel else {
            return nil
        }
        return parsed
    }

    private var facetRangeDescription: String {
        "\(TimeFlipConstants.minFacetID)-\(TimeFlipConstants.maxFacetID)"
    }

    private var batteryRangeDescription: String {
        "\(TimeFlipConstants.minBatteryLevel)-\(TimeFlipConstants.maxBatteryLevel)"
    }

    private func handleStatus() async -> Response {
        .ok(await snapshotAsync().jsonString())
    }

    private func handleFlip(params: [String: String]) -> Response {
        guard let facet = parseFacetID(params["facet"]) else {
            return .badRequest("facet required (\(facetRangeDescription))")
        }
        performOnMain { self.controller.flip(to: facet) }
        return .ok("flip facet=\(facet)")
    }

    private func handleDoubleTap(params: [String: String]) -> Response {
        let facet = params["facet"].flatMap(parseFacetID)
        if let pause = parseBool(params["pause"]) {
            performOnMain { self.controller.setPaused(pause) }
            return .ok("double_tap pause=\(pause)")
        }
        performOnMain { self.controller.doubleTap(targetFacetID: facet) }
        return .ok("double_tap")
    }

    private func handlePause(params: [String: String]) -> Response {
        guard let pause = parseBool(params["on"]) else {
            return .badRequest("on required (true/false)")
        }
        performOnMain { self.controller.setPaused(pause) }
        return .ok("pause=\(pause)")
    }

    private func handleLock(params: [String: String]) -> Response {
        guard let locked = parseBool(params["on"]) else {
            return .badRequest("on required (true/false)")
        }
        performOnMain { self.controller.setLocked(locked) }
        return .ok("lock=\(locked)")
    }

    private func handleAutoPause(params: [String: String]) -> Response {
        guard let minutes = parseUInt16(params["minutes"]) else {
            return .badRequest("minutes required")
        }
        performOnMain { self.controller.setAutoPause(minutes: minutes) }
        return .ok("auto_pause_minutes=\(minutes)")
    }

    private func handleBattery(params: [String: String]) -> Response {
        guard let level = parseBatteryLevel(params["level"]) else {
            return .badRequest("level required (\(batteryRangeDescription))")
        }
        performOnMain { self.controller.setBatteryLevel(level) }
        return .ok("battery level=\(level)")
    }

    private func handleSystem(params: [String: String]) -> Response {
        let status = parseUInt16(params["status"]) ?? 0x0000
        let hardware = parseUInt16(params["hardware"]) ?? 0x0000
        performOnMain {
            self.controller.setSystemState(TimeFlipSystemState(rawStatus: status, rawHardware: hardware))
        }
        return .ok(String(format: "system status=0x%04X hardware=0x%04X", status, hardware))
    }

    private func handleTime(params: [String: String]) -> Response {
        guard let epoch = parseDouble(params["epoch"]) else {
            return .badRequest("epoch required (seconds)")
        }
        performOnMain { self.controller.setDeviceTime(Date(timeIntervalSince1970: epoch)) }
        return .ok("time=\(epoch)")
    }

    private func handleEventLog(params: [String: String]) -> Response {
        guard let message = params["message"], !message.isEmpty else {
            return .badRequest("message required")
        }
        performOnMain { self.controller.appendEventLog(message) }
        return .ok("event_log message=\(message)")
    }

    private func handleLastHistory() async -> Response {
        guard let last = await lastEventNumberAsync() else {
            return .ok("last_event_number=none")
        }
        return .ok("last_event_number=\(last)")
    }

    private func connectionIsLoopback(_ connection: NWConnection) -> Bool {
        let endpoint = connection.endpoint
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        switch host {
        case .ipv4(let address):
            return address.rawValue == Constants.loopbackIPv4
        case .ipv6(let address):
            return address.rawValue == Constants.loopbackIPv6
        default:
            return false
        }
    }

    private var helpText: String {
        [
            "TimeFlip mock HTTP endpoints:",
            "GET /status",
            "GET /flip?facet=\(Constants.helpFacetExample)",
            "GET /double-tap?facet=\(Constants.helpFacetExample)",
            "GET /pause?on=1",
            "GET /lock?on=1",
            "GET /auto-pause?minutes=\(Constants.helpAutoPauseMinutesExample)",
            "GET /battery?level=\(Constants.helpBatteryExample)",
            "GET /system?status=0x0000&hardware=0x0000",
            "GET /time?epoch=\(Int(Constants.helpEpochExample))",
            "GET /event-log?message=hello",
            "GET /history/last"
        ].joined(separator: "\n")
    }
}

private enum Response {
    case ok(String)
    case badRequest(String)
    case notFound(String)
    case forbidden(String)

    var code: Int {
        switch self {
        case .ok:
            return HTTPStatusCode.ok
        case .badRequest:
            return HTTPStatusCode.badRequest
        case .notFound:
            return HTTPStatusCode.notFound
        case .forbidden:
            return HTTPStatusCode.forbidden
        }
    }

    var reason: String {
        switch self {
        case .ok:
            return "OK"
        case .badRequest:
            return "Bad Request"
        case .notFound:
            return "Not Found"
        case .forbidden:
            return "Forbidden"
        }
    }

    var payload: String {
        switch self {
        case let .ok(message), let .badRequest(message), let .notFound(message), let .forbidden(message):
            return message
        }
    }
}

private enum HTTPStatusCode {
    static let ok = 200
    static let badRequest = 400
    static let notFound = 404
    static let forbidden = 403
}
