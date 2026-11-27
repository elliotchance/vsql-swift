// Tests for the paths that the other tests don't reach, such as errors that
// libvsql only returns for bad handles, and the parts of the Decoder protocols
// that Decodable types rarely use.

import CVSQL
import Foundation
import Testing

@testable import VSQL

struct CLITests {
    @Test func invalidHandles() throws {
        #expect(throws: SQLError(sqlstate: "HY000", message: "invalid handle")) {
            try freeHandle(CLI.handleStmt, 999_999)
        }

        // There's no diagnostic record for a handle that doesn't exist.
        #expect(diagnosticField(CLI.handleStmt, 999_999, SQL_DIAG_TABLE_NAME) == nil)
        #expect(
            diagnostics(CLI.handleStmt, 999_999)
                == SQLError(sqlstate: "HY000", message: "unknown error"))
    }

    @Test func routineErrors() throws {
        let db = try Connection()
        #expect(sqlstate { try getInfo(db.handle(), 9999) } != nil)

        let statement = try db.prepare("VALUES 1")
        _ = try statement.cursor()
        #expect(sqlstate { try describeCol(statement.stmt, 2) } != nil)
    }

    @Test func longValues() throws {
        let db = try Connection()

        // An error message that doesn't fit in the first buffer (the message
        // of a CHECK constraint has its expression).
        let long = String(repeating: "z", count: 600)
        try db.execute("CREATE TABLE foo (x INTEGER, CHECK (x > 0 OR '\(long)' = 'a'))")
        do {
            try db.execute("INSERT INTO foo (x) VALUES (-1)")
            Issue.record("no error")
        } catch let error as SQLError {
            #expect(error.message.contains(long), "\(error)")
        }

        // Longer than libvsql's lengths.
        #expect(
            sqlstate { try Connection(path: String(repeating: "a", count: 40_000)) } == "HY090")
    }

    @Test func emptyStatement() throws {
        #expect(sqlstate { try Connection().execute("") } != nil)
    }
}

struct ConnectionCoverageTests {
    @Test func connectFails() throws {
        #expect(sqlstate { try Connection(path: "/nonexistent/folder/db.vsql") } != nil)
    }

    @Test func closeFails() throws {
        let db = try Connection()
        let env = db.env
        db.env = 999_999
        #expect(throws: SQLError.self) { try db.close() }
        try freeHandle(CLI.handleEnv, env)

        // It's closed anyway.
        #expect(sqlstate { try db.execute("VALUES 1") } == "08003")
    }

    @Test func savepointFails() throws {
        let db = try Connection()
        let name = String(repeating: "s", count: 1000)
        #expect(sqlstate { try db.savepoint(name) { _ in } } != nil)
        #expect(db.isAutocommit)
    }

    @Test func rowsOfAFreedStatement() throws {
        let db = try Connection()
        let statement = try db.prepare("VALUES 1")
        statement.free()
        #expect(sqlstate { try Rows(statement) } != nil)
        #expect(statement.parameterCount == 0)
    }

    @Test func errorWhileFetching() throws {
        let db = try Connection()

        // The cursor is closed underneath the rows.
        let statement = try db.prepare("VALUES 1, 2")
        let rows = try statement.cursor()
        try closeCursor(statement.stmt)
        #expect(sqlstate { try rows.next() } == "24000")

        // The rows end after an error.
        #expect(try rows.next() == nil)
    }
}

struct ConversionCoverageTests {
    @Test func conversions() throws {
        #expect(try Int?.some(5).sqlValue() == .integer(5))
        #expect(try Int?.none.sqlValue() == .null)
        #expect(try Bool(sqlValue: .boolean(true)))
        #expect(throws: ConversionError.self) { try Bool(sqlValue: .integer(1)) }
        #expect(try Double(sqlValue: .integer(3)) == 3)
        #expect(throws: ConversionError.invalidValue("x isn't a number")) {
            try Double(sqlValue: .numeric("x"))
        }
        #expect(throws: ConversionError.self) { try Double(sqlValue: .text("1")) }
        #expect(throws: ConversionError.invalidValue("x isn't a decimal number")) {
            try Decimal(sqlValue: .numeric("x"))
        }
        let time = SQLTime(hour: 1, minute: 2, second: 3)
        #expect(try SQLTime(sqlValue: .time(time)) == time)
        #expect(throws: ConversionError.self) { try SQLTime(sqlValue: .null) }
        #expect(throws: ConversionError.unexpectedNull) { try SQLTimestamp(sqlValue: .null) }
    }

    @Test func types() throws {
        #expect(SQLType(code: 9999) == .other(9999))
        #expect(SQLType.other(9999).description == "UNKNOWN")
        #expect(SQLDate(year: 2022, month: 1, day: 2) < SQLDate(year: 2022, month: 2, day: 1))
        #expect(Value.null.isNull)
        #expect(!Value.integer(0).isNull)
    }

    @Test(arguments: [
        (SQLType.boolean, "MAYBE"),
        (.date, "DATE '2022-1-2'"),
        (.time, "TIME '15:04'"),
        (.time, "TIME '15:04:05.1234567'"),
        (.time, "TIME '15:04:05+0530'"),
        (.timestamp, "TIMESTAMP '2022-01-02'"),
        (.interval(.year), "5"),
        (.interval(.year), "INTERVAL '5"),
        (.interval(.yearToMonth), "INTERVAL '1' YEAR TO MONTH"),
        (.interval(.year), "INTERVAL '1.5' YEAR"),
        (.interval(.year), "INTERVAL 'x' YEAR"),
        (.interval(.second), "INTERVAL '1.1234567' SECOND"),
        (.interval(.day), "INTERVAL '99999999999999999999' DAY"),
        (.interval(.year), "INTERVAL '1537228672809129301' YEAR"),
    ])
    func invalidLiterals(type: SQLType, s: String) throws {
        let column = Column(name: "X", type: type, isNullable: true, size: 0, digits: 0)
        #expect(throws: VSQLError.self) { try Value.parse(s, column: column, index: 0) }
    }
}

/// Uses every part of the Decoder protocols.
struct DecoderCoverageTests {
    let db = try! Connection()

    struct Keyed: Decodable {
        enum Keys: String, CodingKey {
            case a = "A"
            case b = "B"
        }

        init(from decoder: any Decoder) throws {
            #expect(decoder.codingPath.isEmpty)
            #expect(decoder.userInfo.isEmpty)
            let c = try decoder.container(keyedBy: Keys.self)
            #expect(c.codingPath.isEmpty)
            #expect(c.allKeys == [.a, .b])
            #expect(throws: DecodingError.self) {
                try c.nestedContainer(keyedBy: Keys.self, forKey: .a)
            }
            #expect(throws: DecodingError.self) { try c.nestedUnkeyedContainer(forKey: .a) }
            #expect(try c.superDecoder().codingPath.isEmpty)
            #expect(try c.superDecoder(forKey: .a).codingPath.isEmpty)
        }
    }

    struct Unkeyed: Decodable {
        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            #expect(c.codingPath.isEmpty)
            #expect(c.count == 2)
            #expect(try !c.decodeNil())
            #expect(try c.decode(Int.self) == 1)
            #expect(try c.decodeNil())
            #expect(c.isAtEnd)
            #expect(try !c.decodeNil())
            #expect(throws: DecodingError.self) { try c.decode(Int.self) }
            #expect(throws: DecodingError.self) { try c.nestedContainer(keyedBy: IndexKey.self) }
            #expect(throws: DecodingError.self) { try c.nestedUnkeyedContainer() }
            #expect(try c.superDecoder().codingPath.isEmpty)
        }
    }

    /// A column decoded with every method of SingleValueDecodingContainer.
    struct Numbers: Decodable {
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            #expect(!c.decodeNil())
            #expect(try c.decode(Int.self) == 7)
            #expect(try c.decode(Int8.self) == 7)
            #expect(try c.decode(Int16.self) == 7)
            #expect(try c.decode(Int32.self) == 7)
            #expect(try c.decode(Int64.self) == 7)
            #expect(try c.decode(UInt.self) == 7)
            #expect(try c.decode(UInt8.self) == 7)
            #expect(try c.decode(UInt16.self) == 7)
            #expect(try c.decode(UInt32.self) == 7)
            #expect(try c.decode(UInt64.self) == 7)
            #expect(try c.decode(Double.self) == 7)
            #expect(try c.decode(Float.self) == 7)
            #expect(try c.decode(Size.self) == .seven)
            #expect(throws: DecodingError.self) { try c.decode(Bool.self) }
            #expect(throws: DecodingError.self) { try c.decode(String.self) }
        }
    }

    enum Size: Int, Decodable {
        case seven = 7
    }

    /// A column that's decoded as a single value of a type that isn't
    /// SQLDecodable.
    struct Wrapper: Decodable {
        var flag: Flag
    }

    struct Flag: Decodable {
        var value: Bool

        init(from decoder: any Decoder) throws {
            #expect(decoder.userInfo.isEmpty)
            #expect(throws: DecodingError.self) { try decoder.container(keyedBy: IndexKey.self) }
            #expect(throws: DecodingError.self) { try decoder.unkeyedContainer() }
            let c = try decoder.singleValueContainer()
            #expect(!c.decodeNil())
            value = try c.decode(Bool.self)
        }
    }

    @Test func decoders() throws {
        try db.execute("CREATE TABLE ab (a INTEGER, b INTEGER, flag BOOLEAN)")
        try db.execute("INSERT INTO ab (a, b, flag) VALUES (1, 2, TRUE)")
        _ = try #require(try db.queryRow("SELECT a, b FROM ab")).decode(Keyed.self)
        _ = try #require(try db.queryRow("VALUES ROW(1, CAST(NULL AS INTEGER))")).decode(
            Unkeyed.self)
        _ = try #require(try db.queryRow("VALUES 7")).decode(Numbers.self)
        let wrapper = try #require(try db.queryRow("SELECT flag FROM ab")).decode(
            Wrapper.self)
        #expect(wrapper.flag.value)

        // A row without any columns.
        #expect(throws: DecodingError.self) {
            try Row(columns: [], values: []).decode(Int.self)
        }

        #expect(IndexKey(intValue: 3)?.stringValue == "3")
        #expect(IndexKey(stringValue: "3") == nil)
    }
}
