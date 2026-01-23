@preconcurrency import CoreBluetooth

@MainActor
enum TimeFlipUUIDs {
    // TimeFlip2 service and characteristic UUIDs from the vendor protocol v4.3.
    static let service = CBUUID(string: "F1196F50-71A4-11E6-BDF4-0800200C9A66")
    static let eventsData = CBUUID(string: "F1196F51-71A4-11E6-BDF4-0800200C9A66")
    static let facets = CBUUID(string: "F1196F52-71A4-11E6-BDF4-0800200C9A66")
    static let commandResult = CBUUID(string: "F1196F53-71A4-11E6-BDF4-0800200C9A66")
    static let command = CBUUID(string: "F1196F54-71A4-11E6-BDF4-0800200C9A66")
    static let doubleTap = CBUUID(string: "F1196F55-71A4-11E6-BDF4-0800200C9A66")
    static let systemState = CBUUID(string: "F1196F56-71A4-11E6-BDF4-0800200C9A66")
    static let password = CBUUID(string: "F1196F57-71A4-11E6-BDF4-0800200C9A66")
    static let history = CBUUID(string: "F1196F58-71A4-11E6-BDF4-0800200C9A66")

    // Standard BLE service UUIDs.
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")

    // Device Information service + characteristics (standard GATT 0x180A).
    static let deviceInfoService = CBUUID(string: "180A")
    static let manufacturerName = CBUUID(string: "2A29")
    static let modelNumber = CBUUID(string: "2A24")
    static let hardwareRevision = CBUUID(string: "2A27")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let systemID = CBUUID(string: "2A23")
}
