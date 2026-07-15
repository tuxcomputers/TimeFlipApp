import Foundation

struct DiscoveredBLEDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}
