import Foundation
import Testing

@testable import VSQL

struct ConnectionTests {
    let db = try! Connection()

    @Test func columns() throws {
        try db.execute("CREATE TABLE foo (a INTEGER NOT NULL, b VARCHAR(20), c NUMERIC(10, 3))")
        let rows = try db.cursor("SELECT * FROM foo")
        #expect(rows.columnNames == ["A", "B", "C"])
        let columns = rows.columns
        #expect(!columns[0].isNullable)
        #expect(columns[1].isNullable)
        #expect(columns[1].length == 20)
        #expect(columns[0].length == nil)
        #expect(columns[2].precision == 10)
        #expect(columns[2].scale == 3)
        #expect(columns[0].precision == nil)
        #expect(columns[2].type.description == "NUMERIC")
        #expect(try rows.next() == nil)
    }

    @Test func columnNamesAndIndexes() throws {
        let r = try row(db, "VALUES ROW(1, 2)")
        #expect(r.count == 2)
        #expect(Array(r) == [.integer(1), .integer(2)])
        #expect(r.columnNames == ["COL1", "COL2"])
        #expect(try r.get("COL2") as Int == 2)
        #expect(try r.get("col2") as Int == 2)
        #expect(r["col2"] == .integer(2))
        #expect(r["nope"] == nil)
        #expect(throws: VSQLError.columnNotFound("nope")) { try r.get("nope") as Int }
        #expect(throws: VSQLError.columnIndexOutOfRange(2)) { try r.get(2) as Int }
    }

    @Test func parameters() throws {
        try db.execute(
            """
            CREATE TABLE foo (
                s SMALLINT, i INTEGER, b BIGINT, r REAL, d DOUBLE PRECISION,
                n NUMERIC(30, 5), c VARCHAR(100), bo BOOLEAN,
                ts TIMESTAMP(6), tz TIMESTAMP(6) WITH TIME ZONE, dt DATE,
                tm TIME(6), tt TIME(6) WITH TIME ZONE)
            """)

        let date = SQLDate(year: 2022, month: 1, day: 2)
        let time = SQLTime(hour: 15, minute: 4, second: 5, microsecond: 123456)
        var timeTZ = time
        timeTZ.offset = -240
        func check(_ column: String, _ argument: (any SQLEncodable)?, _ want: Value) throws {
            try db.execute("DELETE FROM foo")
            try db.execute("INSERT INTO foo (\(column)) VALUES (?)", argument)
            #expect(try row(db, "SELECT \(column) FROM foo")[0] == want, "\(column)")
        }

        try check("s", 12, .integer(12))
        try check("i", Int32(-12), .integer(-12))
        try check("b", Int64.max, .integer(.max))
        try check("r", Float(1.5), .double(1.5))
        try check("d", 1.25, .double(1.25))
        try check("n", 7, .numeric("7.00000"))
        try check("n", 1.5, .numeric("1.50000"))
        try check("n", Value.numeric("-1.25"), .numeric("-1.25000"))
        // vsql counts a digit before the decimal point (vsql-go#3).
        try check("n", Value.numeric("0.25"), .numeric("0.25000"))
        try check("n", Value.numeric("-0.00005"), .numeric("-0.00005"))
        try check("n", Value.numeric("0"), .numeric("0.00000"))
        try check("n", Decimal(string: "-12.5"), .numeric("-12.50000"))
        try check("n", UInt64.max, .numeric("18446744073709551615.00000"))
        try check("c", "héllo", .text("héllo"))
        try check("c", "", .text(""))
        try check("c", "sub string".dropFirst(4), .text("string"))
        try check("bo", true, .boolean(true))
        try check("bo", false, .boolean(false))
        try check("dt", date, .date(date))
        try check("tm", time, .time(time))
        try check("tt", timeTZ, .time(timeTZ))
        try check(
            "ts", SQLTimestamp(date: date, time: time), .timestamp(.init(date: date, time: time)))
        try check(
            "tz", SQLTimestamp(date: date, time: timeTZ),
            .timestamp(.init(date: date, time: timeTZ)))
        try check("i", nil, .null)
        try check("i", Int?.none, .null)
        try check("c", String?.none, .null)
        try check("bo", Value.null, .null)
        try check("dt", SQLDate?.none, .null)
    }

    @Test func argumentForms() throws {
        let sql = "VALUES CAST(? AS INTEGER) + CAST(? AS INTEGER)"
        #expect(try db.queryValue(sql, 1, 2) == 3)
        #expect(try db.queryValue(sql, arguments: [1, 2]) == 3)
        #expect(try db.queryValue(sql, arguments: [1, Int8(2)]) == 3)
        let ids = [1, 2]
        #expect(try db.queryValue(sql, arguments: ids) == 3)
        #expect(try db.prepare(sql).queryRow(1, 2)?.get(0) == 3)
    }

    @Test func parameterErrors() throws {
        let sql = "VALUES CAST(? AS INTEGER)"

        // Too few parameters.
        #expect(sqlstate { try db.queryRow(sql) } == "07001")

        // A NUMERIC that isn't a decimal.
        #expect(
            throws: VSQLError.invalidParameter(index: 1, reason: "\"1e5\" isn't a decimal number")
        ) { try db.queryRow(sql, Value.numeric("1e5")) }
        #expect(throws: VSQLError.self) { try db.queryRow(sql, Decimal.nan) }
    }

    @Test func errors() throws {
        for (sql, want) in [
            ("SELECT * FROM nope", "42P01"),
            ("SELEC 1", "42601"),
            // Transactions are started with Connection.transaction.
            ("COMMIT", "42000"),
            ("VALUES 1 / 0", "22012"),
        ] {
            do {
                try db.execute(sql)
                Issue.record("\(sql) didn't fail")
            } catch let error as SQLError {
                #expect(error.sqlstate == want, "\(sql)")
                #expect(error.description.hasSuffix("(SQLSTATE \(want))"), "\(error)")
            }

            // The connection still works after an error.
            #expect(try db.queryValue("VALUES 1") == 1)
        }

        #expect(sqlstate { try db.prepare("SELEC 1") } == "42601")

        try db.execute("CREATE TABLE foo (x INTEGER NOT NULL)")
        #expect(
            sqlstate { try db.execute("INSERT INTO foo (x) VALUES (NULL)") }?.hasPrefix("23")
                == true)
    }

    @Test func noRows() throws {
        try db.execute("CREATE TABLE foo (x INTEGER)")
        #expect(try db.queryRow("SELECT x FROM foo") == nil)
        #expect(try db.queryValue("SELECT x FROM foo") as Int? == nil)
        #expect(try db.query("SELECT x FROM foo").isEmpty)
    }

    @Test func rowsChanged() throws {
        try db.execute("CREATE TABLE foo (x INTEGER)")
        #expect(try db.execute("INSERT INTO foo (x) VALUES (1)") == 1)
        #expect(try db.execute("INSERT INTO foo (x) VALUES (?)", 2) == 1)
        #expect(try db.execute("UPDATE foo SET x = x + 1") == 2)

        // A query's cursor is closed, so the table can be dropped.
        try db.execute("SELECT * FROM foo")
        try db.execute("SELECT * FROM foo WHERE x = ?", 2)
        try db.execute("DROP TABLE foo")
    }

    @Test func preparedStatements() throws {
        try db.execute("CREATE TABLE foo (x INTEGER)")
        let insert = try db.prepare("INSERT INTO foo (x) VALUES (?)")
        for i in 1...10 {
            #expect(try insert.execute(i) == 1)
        }

        // Each statement has its own cursor, so the rows of one are still
        // open while another is executed.
        let query1 = try db.prepare("SELECT x FROM foo WHERE x > ? ORDER BY x")
        let query2 = try db.prepare("SELECT x FROM foo WHERE x > ? ORDER BY x")
        let rows1 = try query1.cursor(5)
        let rows2 = try query2.cursor(8)
        #expect(try rows2.next()?.get(0) == 9)
        #expect(try rows1.next()?.get(0) == 6)
        #expect(try query2.query(8).count == 2)

        // Executing a statement again closes its cursor.
        #expect(try query1.query(5).count == 5)
        #expect(try rows1.next() == nil)

        // With fewer arguments it's an error rather than reading the old ones
        // (vsql-go#4).
        let two = try db.prepare("VALUES ROW(CAST(? AS VARCHAR(10)), CAST(? AS VARCHAR(10)))")
        #expect(try two.queryRow("a", "b")?.get(1) == "b")
        #expect(sqlstate { try two.queryRow("a") } == "07001")
    }

    @Test func cursors() throws {
        let statement = try db.prepare("VALUES 1, 2, 3")
        let rows = try statement.cursor()
        var xs: [Int] = []
        while let row = try rows.next() {
            xs.append(try row.get(0))
        }
        #expect(xs == [1, 2, 3])
        #expect(try rows.next() == nil)

        // Rows that aren't all read close their cursor when they're no longer
        // used (or closed).
        #expect(try statement.cursor().next()?.get(0) == 1)
        let partial = try statement.cursor()
        _ = try partial.next()
        try partial.close()
        try partial.close()
        #expect(try partial.next() == nil)
        #expect(try statement.query().map { try $0.get(0) as Int } == [1, 2, 3])
    }

    @Test func decoding() throws {
        enum Size: String, Decodable {
            case small = "S"
            case large = "L"
        }
        struct Product: Decodable, Equatable {
            var id: Int
            var name: String
            var price: Decimal?
            var size: Size
            var added: SQLDate?
            var notAColumn: String?
        }

        try db.execute(
            """
            CREATE TABLE products (
                id INTEGER, name VARCHAR(10), price NUMERIC(5, 2), size CHAR(1), added DATE)
            """)
        try db.execute(
            "INSERT INTO products VALUES (1, 'Bolt', 0.25, 'S', DATE '2024-01-02'), "
                + "(2, 'Nut', NULL, 'L', NULL)")

        let products = try db.query(Product.self, "SELECT * FROM products ORDER BY id")
        #expect(
            products == [
                Product(
                    id: 1, name: "Bolt", price: Decimal(string: "0.25"), size: .small,
                    added: SQLDate(year: 2024, month: 1, day: 2)),
                Product(id: 2, name: "Nut", price: nil, size: .large, added: nil),
            ])

        // A single value is the first column, and a tuple-like type is the
        // columns in order.
        #expect(try db.query(Int.self, "SELECT id FROM products ORDER BY id") == [1, 2])
        #expect(try db.query([String].self, "VALUES ROW('a', 'b')") == [["a", "b"]])

        // A missing column, NULL for a property that isn't Optional, and the
        // wrong type.
        struct Missing: Decodable { var nope: Int }
        #expect(throws: DecodingError.self) { try db.query(Missing.self, "SELECT * FROM products") }
        struct NotNull: Decodable { var price: Decimal }
        #expect(throws: DecodingError.self) { try db.query(NotNull.self, "SELECT * FROM products") }
        struct WrongType: Decodable { var name: Int }
        #expect(throws: DecodingError.self) {
            try db.query(WrongType.self, "SELECT * FROM products")
        }
    }

    @Test func transactions() throws {
        let path = TempPath()
        func count() throws -> Int? {
            try Connection(path: path.path).queryValue("SELECT COUNT(*) FROM foo")
        }

        let db = try Connection(path: path.path)
        try db.execute("CREATE TABLE foo (x INTEGER)")
        #expect(db.isAutocommit)

        // Autocommit: another connection sees it.
        try db.execute("INSERT INTO foo (x) VALUES (1)")
        #expect(try count() == 1)

        // Commit.
        let result = try db.transaction { db in
            #expect(!db.isAutocommit)
            try db.execute("INSERT INTO foo (x) VALUES (2)")
            #expect(try count() == 1)
            return "done"
        }
        #expect(result == "done")
        #expect(db.isAutocommit)
        #expect(try count() == 2)

        // Rollback.
        struct Rollback: Error {}
        #expect(throws: Rollback.self) {
            try db.transaction { db in
                try db.execute("INSERT INTO foo (x) VALUES (3)")
                #expect(try db.queryValue("SELECT COUNT(*) FROM foo") == 3)
                throw Rollback()
            }
        }
        #expect(db.isAutocommit)
        #expect(try count() == 2)

        // Transactions can't be nested.
        try db.transaction { db in
            let nested = sqlstate { try db.transaction { _ in } }
            #expect(nested == "25001")
        }
        #expect(db.isAutocommit)

        // Closing a connection rolls back its transaction.
        try? db.transaction { db in
            try db.execute("INSERT INTO foo (x) VALUES (5)")
            try db.close()
        }
        #expect(try count() == 2)
    }

    @Test(arguments: [
        (IsolationLevel.readUncommitted, false, true),
        (.readCommitted, false, false),
        (.repeatableRead, false, false),
        (.serializable, false, false),
        (.readCommitted, true, true),
    ])
    func isolationLevels(isolation: IsolationLevel, readOnly: Bool, wantReadOnly: Bool) throws {
        try db.execute("CREATE TABLE foo (x INTEGER)")
        let insert = "INSERT INTO foo (x) VALUES (1)"
        try db.transaction(isolation: isolation, readOnly: readOnly) { db throws in
            if wantReadOnly {
                #expect(sqlstate { try db.execute(insert) } == "25006")
            } else {
                #expect(try db.execute(insert) == 1)
            }
        }
        #expect(db.isAutocommit)
    }

    @Test func savepoints() throws {
        try db.execute("CREATE TABLE foo (x INTEGER)")
        func insert(_ x: Int) throws {
            try db.execute("INSERT INTO foo (x) VALUES (?)", x)
        }
        func xs() throws -> [Int] {
            try db.query(Int.self, "SELECT x FROM foo ORDER BY x")
        }
        struct Rollback: Error {}

        try db.transaction { db in
            try insert(1)
            try db.savepoint { sp in
                try insert(2)
                // The savepoint is still active after it's rolled back to.
                try sp.rollback()
                #expect(try xs() == [1])
                try insert(3)
                try sp.rollback()
                try insert(4)
                #expect(throws: Rollback.self) {
                    try db.savepoint { _ in
                        try insert(5)
                        throw Rollback()
                    }
                }
                #expect(try xs() == [1, 4])
                try db.savepoint("it's \"quoted\"") { _ in
                    try insert(6)
                }
            }
            #expect(try xs() == [1, 4, 6])
            try? db.savepoint { _ in
                try insert(7)
                throw Rollback()
            }
            #expect(try xs() == [1, 4, 6])
        }

        // A savepoint outside of a transaction starts one.
        try db.savepoint { sp in
            #expect(!db.isAutocommit)
            try insert(8)
            try sp.rollback()
            try insert(9)
        }
        #expect(db.isAutocommit)
        #expect(try xs() == [1, 4, 6, 9])

        // Throwing rolls back the transaction.
        try? db.savepoint("sp") { _ in
            try insert(10)
            throw Rollback()
        }
        #expect(db.isAutocommit)
        #expect(try xs() == [1, 4, 6, 9])
    }

    @Test func diagnostics() throws {
        try db.execute(
            "CREATE TABLE foo (id INTEGER PRIMARY KEY, v INTEGER, CONSTRAINT vpos CHECK (v > 0))")
        try db.execute("INSERT INTO foo (id, v) VALUES (1, 1)")

        func diagnostics(_ sql: String) -> Diagnostics? {
            do {
                try db.execute(sql)
                return nil
            } catch {
                return (error as? SQLError)?.diagnostics
            }
        }

        let d = try #require(diagnostics("INSERT INTO foo (id, v) VALUES (1, 2)"))
        #expect(d.constraintName == "FOO_PRIMARY_KEY")
        #expect(d.constraintSchema == "PUBLIC")
        #expect(d.constraintCatalog == ":memory:")
        #expect(d.tableName == "FOO")
        #expect(d.schemaName == "PUBLIC")
        #expect(d.catalogName == ":memory:")
        #expect(d.columnName == nil)

        #expect(diagnostics("INSERT INTO foo (id, v) VALUES (2, -1)")?.constraintName == "VPOS")
        #expect(diagnostics("SELECT * FROM nope")?.tableName == "NOPE")
        #expect(diagnostics("SELECT * FROM nope")?.constraintName == nil)
        #expect(diagnostics("SELECT nope FROM foo")?.columnName == "NOPE")
        #expect(diagnostics("VALUES 1 / 0") == Diagnostics())
    }

    @Test func parameterCount() throws {
        #expect(try db.prepare("VALUES 1").parameterCount == 0)
        #expect(
            try db.prepare("VALUES CAST(? AS INTEGER) + CAST(? AS INTEGER)").parameterCount == 2)
    }

    @Test func persistence() throws {
        let path = TempPath()
        do {
            let db = try Connection(url: URL(fileURLWithPath: path.path))
            try db.execute("CREATE TABLE foo (x VARCHAR(10))")
            try db.execute("INSERT INTO foo (x) VALUES ('saved')")
        }

        #expect(try Connection(path: path.path).queryValue("SELECT x FROM foo") == "saved")
    }

    @Test func memoryDatabasesAreSeparate() throws {
        let a = try Connection()
        let b = try Connection()
        try a.execute("CREATE TABLE foo (x INTEGER)")
        #expect(sqlstate { try b.execute("SELECT * FROM foo") } == "42P01")
    }

    @Test func closing() throws {
        let db = try Connection()
        let statement = try db.prepare("VALUES 1, 2")
        let rows = try statement.cursor()
        #expect(try rows.next()?.get(0) == 1)

        // Closing the connection frees its statements (and closes their
        // cursors), which can't be used after.
        try db.close()
        try db.close()
        #expect(try rows.next() == nil)
        #expect(sqlstate { try statement.execute() } == "08003")
        #expect(sqlstate { try db.execute("VALUES 1") } == "08003")
        #expect(sqlstate { try db.prepare("VALUES 1") } == "08003")
    }

    /// Many connections from many threads, with enough work for the garbage
    /// collector to run.
    @Test func concurrency() throws {
        let path = TempPath()
        try Connection(path: path.path).execute("CREATE TABLE foo (g INTEGER, x INTEGER)")

        let (threads, inserts) = (8, 50)
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: threads) { g in
            do {
                let db = try Connection(path: path.path)
                for i in 0..<inserts {
                    try db.execute("INSERT INTO foo (g, x) VALUES (?, ?)", g, i)
                    let n: Int? = try db.queryValue("SELECT COUNT(*) FROM foo WHERE g = ?", g)
                    if n != i + 1 {
                        failures.append("thread \(g): \(String(describing: n)) rows, not \(i + 1)")
                    }
                }
            } catch {
                failures.append("thread \(g): \(error)")
            }
        }
        #expect(failures.all.isEmpty)
        #expect(
            try Connection(path: path.path).queryValue("SELECT COUNT(*) FROM foo") == threads
                * inserts)
    }

    @Test func version() throws {
        let version = VSQLLibrary.version
        let parts = version.split(separator: ".").compactMap { Int($0) }
        #expect(parts.count == 3, "\(version)")
        #expect(VSQLLibrary.versionNumber == parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2])
        #expect(VSQLLibrary.versionNumber >= 1_008_002)

        let info = VSQLLibrary.buildInfo
        #expect(info.version.isEmpty || info.version.dropFirst() == version)
        #expect(!info.vVersion.isEmpty)
        #expect(!info.date.isEmpty)
    }
}

/// Failures from many threads.
final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    func append(_ failure: String) {
        lock.lock()
        defer { lock.unlock() }
        failures.append(failure)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}
