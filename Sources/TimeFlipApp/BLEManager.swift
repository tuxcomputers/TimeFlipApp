import CoreBluetooth
import OSLog

@MainActor
final class BLEManager: NSObject {
    private let central: CentralManaging
    private let logger: Logger

    init(
        central: CentralManaging? = nil,
        logger: Logger = Logger(subsystem: AppIdentifiers.subsystem, category: "ble")
    ) {
        self.central = central ?? CBCentralManager()
        self.logger = logger
        super.init()
        self.central.delegate = self
    }

    func start() {
        logger.notice("BLE manager start requested; state=\(self.central.state.rawValue, privacy: .public)")
        handleStateChange(self.central.state)
    }

    func stop() {
        central.stopScan()
        logger.info("Stopped scanning for TimeFlip")
    }

    func handleStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            logger.error("Bluetooth powered off; cannot scan")
        case .unauthorized:
            logger.error("Bluetooth unauthorized; update permissions")
        case .unsupported:
            logger.error("Bluetooth unsupported on this device")
        case .resetting:
            logger.info("Bluetooth resetting; will retry scan when ready")
        case .unknown:
            logger.info("Bluetooth state unknown")
        @unknown default:
            logger.error("Bluetooth entered unknown future state")
        }
    }

    private func startScanning() {
        logger.notice("Starting scan for TimeFlip service \(TimeFlipUUIDs.service.uuidString, privacy: .public)")
        central.scanForPeripherals(
            withServices: [TimeFlipUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.handleStateChange(state)
        }
    }
}
