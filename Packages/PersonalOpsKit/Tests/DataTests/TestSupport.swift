import Foundation
import SwiftData
import XCTest
@testable import Data

/// Shared helpers for the Data test target. Every test runs against an in-memory
/// `ModelContainer` (nothing touches disk) built from the same versioned schema the app
/// ships, so tests exercise the real migration/container path.
enum TestContainer {
    static func make() throws -> ModelContainer {
        try DataStore.makeContainer(inMemory: true)
    }

    /// A fresh in-memory context.
    static func context() throws -> ModelContext {
        ModelContext(try make())
    }
}
