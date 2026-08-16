import Foundation
@testable import TimeFlipApp

// Shared test-only database URL so unit tests never touch the real app data store.
let historyIngestorTestDBURL: URL = {
    AppDataStore.testDatabaseURL()
}()
