import Foundation
import Testing

@testable import VSQL

/// A path for a new database file, and the files next to it (such as the
/// write-ahead log) are removed when it's no longer used.
final class TempPath: Sendable {
    let path: String

    init() {
        path =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("vsql-swift-test-\(UUID().uuidString).vsql").path
    }

    deinit {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasPrefix(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

/// The SQLSTATE of the SQLError that body throws.
func sqlstate<T>(_ body: () throws -> T) -> String? {
    do {
        _ = try body()
        return nil
    } catch let error as SQLError {
        return error.sqlstate
    } catch {
        return "not an SQLError: \(error)"
    }
}

/// The first row of a query, which must have one.
func row(_ db: Connection, _ sql: String, _ arguments: (any SQLEncodable)?...) throws -> Row {
    try #require(try db.queryRow(sql, arguments: arguments))
}
