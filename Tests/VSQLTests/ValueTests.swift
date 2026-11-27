import Foundation
import Testing

@testable import VSQL

struct ValueTests {
    let db = try! Connection()

    @Test(arguments: [
        ("CAST(12 AS SMALLINT)", Value.integer(12), SQLType.smallInt),
        ("CAST(-12 AS INTEGER)", .integer(-12), .integer),
        ("CAST(9223372036854775807 AS BIGINT)", .integer(.max), .bigInt),
        ("CAST(1.5 AS REAL)", .double(1.5), .real),
        ("CAST(1.25 AS DOUBLE PRECISION)", .double(1.25), .doublePrecision),
        ("CAST(1.5 AS DECIMAL(10, 3))", .numeric("1.500"), .decimal),
        ("CAST(12 AS NUMERIC(10, 2))", .numeric("12.00"), .numeric),
        ("CAST('ab' AS CHARACTER(4))", .text("ab  "), .character),
        ("CAST('héllo' AS VARCHAR(10))", .text("héllo"), .characterVarying),
        ("TRUE", .boolean(true), .boolean),
        ("FALSE", .boolean(false), .boolean),
        ("DATE '2022-01-02'", .date(SQLDate(year: 2022, month: 1, day: 2)), .date),
        (
            "TIME '15:04:05.123456'",
            .time(SQLTime(hour: 15, minute: 4, second: 5, microsecond: 123456)), .time
        ),
        (
            "TIME '15:04:05+05:30'",
            .time(SQLTime(hour: 15, minute: 4, second: 5, offset: 330)), .timeWithTimeZone
        ),
        (
            "TIMESTAMP '2022-01-02 15:04:05.5'",
            .timestamp(
                SQLTimestamp(
                    date: SQLDate(year: 2022, month: 1, day: 2),
                    time: SQLTime(hour: 15, minute: 4, second: 5, microsecond: 500000))),
            .timestamp
        ),
        (
            "TIMESTAMP '2022-01-02 15:04:05.123-04:00'",
            .timestamp(
                SQLTimestamp(
                    date: SQLDate(year: 2022, month: 1, day: 2),
                    time: SQLTime(
                        hour: 15, minute: 4, second: 5, microsecond: 123000, offset: -240))),
            .timestampWithTimeZone
        ),
        ("X'00ff'", .binary([0, 255]), .binary),
        ("CAST(X'01' AS BINARY VARYING(5))", .binary([1]), .binaryVarying),
        ("CAST(X'01' AS BLOB)", .binary([1]), .binaryLargeObject),
        ("CAST(NULL AS BLOB)", .null, .binaryLargeObject),
        ("CAST('ab' AS CLOB)", .text("ab"), .characterLargeObject),
        ("CAST(1.5E20 AS DECFLOAT)", .decFloat("1.5E+20"), .decFloat),
        ("CAST(-0.25 AS DECFLOAT)", .decFloat("-0.25"), .decFloat),
        (
            "INTERVAL '-1-2' YEAR TO MONTH",
            .interval(SQLInterval(fields: .yearToMonth, months: -14)), .interval(.yearToMonth)
        ),
        (
            "INTERVAL '1 2:3:4.5' DAY TO SECOND",
            .interval(SQLInterval(fields: .dayToSecond, microseconds: 93_784_500_000)),
            .interval(.dayToSecond)
        ),
        ("CAST(NULL AS INTERVAL DAY)", .null, .interval(.day)),
        ("CAST(NULL AS INTEGER)", .null, .integer),
        ("CAST(NULL AS BOOLEAN)", .null, .boolean),
        ("CAST(NULL AS DATE)", .null, .date),
    ])
    func columnValues(expression: String, value: Value, type: SQLType) throws {
        let rows = try db.cursor("VALUES \(expression)")
        #expect(rows.columns[0].type == type)
        let row = try #require(try rows.next())
        #expect(row[0] == value)
        #expect(try row.get(0) as Value == value)
        #expect(try rows.next() == nil)
    }

    /// https://github.com/elliotchance/vsql/issues/697
    @Test func fractionalSecondsWithLeadingZeros() throws {
        let t: SQLTimestamp? = try db.queryValue("VALUES TIMESTAMP '2022-01-02 15:04:05.000006'")
        #expect(t?.time.microsecond == 6)
    }

    @Test func swiftTypes() throws {
        func value<T: SQLDecodable>(_ sql: String, as type: T.Type = T.self) throws -> T {
            try row(db, "VALUES \(sql)").get(0)
        }

        #expect(try value("CAST(12 AS SMALLINT)") as Int16 == 12)
        #expect(try value("CAST(12 AS SMALLINT)") as UInt8 == 12)
        #expect(try value("CAST(12 AS BIGINT)") as Int == 12)
        #expect(try value("CAST(1.5 AS REAL)") as Float == 1.5)
        #expect(try value("CAST(1.5 AS NUMERIC(5, 2))") as Double == 1.5)
        #expect(try value("CAST(1.5 AS NUMERIC(5, 2))") as String == "1.50")
        #expect(try value("CAST(1.5 AS NUMERIC(5, 2))") as Decimal == Decimal(string: "1.5"))
        #expect(try value("CAST(7 AS INTEGER)") as Decimal == 7)
        #expect(try value("CAST(NULL AS INTEGER)") as Int? == nil)
        #expect(try value("CAST(3 AS INTEGER)") as Int? == 3)
        #expect(try value("X'0102'") as Data == Data([1, 2]))
        #expect(try value("X'0102'") as [UInt8] == [1, 2])

        // Out of range, the wrong type, and NULL without an Optional.
        #expect(
            throws: VSQLError.conversionFailed(
                column: 0, name: "COL1", type: .integer, reason: .outOfRange(.integer(100000)))
        ) { try value("CAST(100000 AS INTEGER)") as Int16 }
        #expect(
            throws: VSQLError.conversionFailed(
                column: 0, name: "COL1", type: .characterVarying,
                reason: .typeMismatch(expected: "Int", value: .text("a")))
        ) { try value("CAST('a' AS VARCHAR(1))") as Int }
        #expect(
            throws: VSQLError.conversionFailed(
                column: 0, name: "COL1", type: .integer, reason: .unexpectedNull)
        ) { try value("CAST(NULL AS INTEGER)") as Int }
    }

    @Test func foundationDates() throws {
        // 2022-01-02 15:04:05.123456 UTC.
        let date = Date(timeIntervalSince1970: 1_641_135_845.123456)
        let timestamp = SQLTimestamp(date)
        #expect(timestamp.description == "2022-01-02 15:04:05.123456+00:00")
        #expect(SQLTimestamp(date, offset: 330).description == "2022-01-02 20:34:05.123456+05:30")
        #expect(SQLTimestamp(date, offset: nil).description == "2022-01-02 15:04:05.123456")
        #expect(abs(timestamp.foundationDate.timeIntervalSince(date)) < 1e-6)
        #expect(
            SQLTimestamp(Date(timeIntervalSince1970: -1.5)).description
                == "1969-12-31 23:59:58.500000+00:00")

        try db.execute("CREATE TABLE foo (tz TIMESTAMP(6) WITH TIME ZONE, ts TIMESTAMP(6))")
        try db.execute("INSERT INTO foo (tz, ts) VALUES (?, ?)", date, date)
        let r = try row(db, "SELECT tz, ts FROM foo")
        for i in 0..<2 {
            let got: Date = try r.get(i)
            #expect(abs(got.timeIntervalSince(date)) < 1e-6)
        }
        let tz: SQLTimestamp = try r.get("tz")
        #expect(tz.time.offset == 0)

        // A TIMESTAMP WITH TIME ZONE in another time zone is the same instant.
        let other: Date? = try db.queryValue(
            "VALUES TIMESTAMP '2022-01-02 20:34:05.123456+05:30'")
        #expect(abs(other!.timeIntervalSince(date)) < 1e-6)
    }

    @Test func valueLiterals() {
        let values: [Value] = [nil, true, 1, 1.5, "it's"]
        #expect(values == [.null, .boolean(true), .integer(1), .double(1.5), .text("it's")])
        #expect(values.map(\.description) == ["NULL", "TRUE", "1", "1.5", "'it''s'"])
        #expect(Value.binary([0, 255]).description == "X'00FF'")
        #expect(
            Value.date(SQLDate(year: 2022, month: 1, day: 2)).description == "DATE '2022-01-02'")
    }

    @Test(arguments: [
        ("INTERVAL '5' YEAR", SQLInterval(fields: .year, months: 60), "INTERVAL '5' YEAR(2)"),
        (
            "INTERVAL '100' YEAR(3)", SQLInterval(fields: .year, months: 1200),
            "INTERVAL '100' YEAR(3)"
        ),
        ("INTERVAL '7' MONTH", SQLInterval(fields: .month, months: 7), "INTERVAL '7' MONTH(2)"),
        (
            "INTERVAL '3' DAY", SQLInterval(fields: .day, microseconds: 259_200_000_000),
            "INTERVAL '3' DAY(2)"
        ),
        (
            "INTERVAL '3' HOUR", SQLInterval(fields: .hour, microseconds: 10_800_000_000),
            "INTERVAL '3' HOUR(2)"
        ),
        (
            "INTERVAL '3' MINUTE", SQLInterval(fields: .minute, microseconds: 180_000_000),
            "INTERVAL '3' MINUTE(2)"
        ),
        (
            "INTERVAL '3.25' SECOND", SQLInterval(fields: .second, microseconds: 3_250_000),
            "INTERVAL '3.250000' SECOND(2, 6)"
        ),
        (
            "INTERVAL '-1-2' YEAR TO MONTH", SQLInterval(fields: .yearToMonth, months: -14),
            "INTERVAL '-1-02' YEAR(2) TO MONTH"
        ),
        (
            "INTERVAL '1 2' DAY TO HOUR",
            SQLInterval(fields: .dayToHour, microseconds: 93_600_000_000),
            "INTERVAL '1 02' DAY(2) TO HOUR"
        ),
        (
            "INTERVAL '1 2:3' DAY TO MINUTE",
            SQLInterval(fields: .dayToMinute, microseconds: 93_780_000_000),
            "INTERVAL '1 02:03' DAY(2) TO MINUTE"
        ),
        (
            "INTERVAL '-1 2:3:4.5' DAY TO SECOND",
            SQLInterval(fields: .dayToSecond, microseconds: -93_784_500_000),
            "INTERVAL '-1 02:03:04.500000' DAY(2) TO SECOND(6)"
        ),
        (
            "INTERVAL '2:3' HOUR TO MINUTE",
            SQLInterval(fields: .hourToMinute, microseconds: 7_380_000_000),
            "INTERVAL '2:03' HOUR(2) TO MINUTE"
        ),
        (
            "INTERVAL '2:3:4' HOUR TO SECOND",
            SQLInterval(fields: .hourToSecond, microseconds: 7_384_000_000),
            "INTERVAL '2:03:04.000000' HOUR(2) TO SECOND(6)"
        ),
        (
            "INTERVAL '3:4.000001' MINUTE TO SECOND",
            SQLInterval(fields: .minuteToSecond, microseconds: 184_000_001),
            "INTERVAL '3:04.000001' MINUTE(2) TO SECOND(6)"
        ),
        (
            "INTERVAL '-0:00.5' MINUTE TO SECOND",
            SQLInterval(fields: .minuteToSecond, microseconds: -500_000),
            "INTERVAL '-0:00.500000' MINUTE(2) TO SECOND(6)"
        ),
    ])
    func intervals(sql: String, want: SQLInterval, literal: String) throws {
        let r = try row(db, "VALUES \(sql)")
        #expect(r.columns[0].type == .interval(want.fields))
        #expect(try r.get(0) as SQLInterval == want)

        // The literal is the same as vsql's.
        #expect(want.description == literal)
        let got: String? = try db.queryValue("VALUES CAST(\(sql) AS VARCHAR(100))")
        #expect(got == literal)

        // As a parameter.
        let qualifier = literal.split(separator: "' ", maxSplits: 1)[1]
        let back: SQLInterval? = try db.queryValue(
            "VALUES CAST(? AS INTERVAL \(qualifier))", want)
        #expect(back == want)
    }

    @Test func intervalColumns() throws {
        #expect(SQLType.interval(.dayToSecond).description == "INTERVAL DAY TO SECOND")
        #expect(IntervalFields.dayToSecond.description == "DAY TO SECOND")
        #expect(IntervalFields.yearToMonth.isYearMonth)
        #expect(!IntervalFields.day.isYearMonth)

        // An interval column, and one that's out of the range of its type.
        try db.execute("CREATE TABLE foo (x INTERVAL DAY TO SECOND)")
        let want = SQLInterval(fields: .dayToSecond, microseconds: -93_784_500_000)
        try db.execute("INSERT INTO foo (x) VALUES (?)", want)
        #expect(try db.queryValue("SELECT x FROM foo") == want)
        let tooBig = SQLInterval(fields: .dayToSecond, microseconds: 100 * 86_400_000_000)
        #expect(sqlstate { try db.execute("INSERT INTO foo (x) VALUES (?)", tooBig) } == "22015")
    }

    @Test func binaryStrings() throws {
        try db.execute("CREATE TABLE foo (v BINARY VARYING(2000), b BINARY(4), l BLOB)")

        // Values that are read in more than one piece, and an empty one.
        let long = (0..<1000).map { UInt8($0 % 251) }
        for want in [[], [0, 1, 2, 255], long] as [[UInt8]] {
            try db.execute("DELETE FROM foo")
            try db.execute("INSERT INTO foo (v, l) VALUES (?, ?)", want, Data(want))
            let r = try row(db, "SELECT v, l FROM foo")
            #expect(try r.get(0) as [UInt8] == want)
            #expect(try r.get(1) as Data == Data(want))
        }

        // A BINARY is padded with zeros.
        try db.execute("DELETE FROM foo")
        try db.execute("INSERT INTO foo (b) VALUES (?)", [1, 2] as [UInt8])
        let r = try row(db, "SELECT b, v FROM foo")
        #expect(try r.get(0) as [UInt8] == [1, 2, 0, 0])
        #expect(try r.get(1) as [UInt8]? == nil)
        #expect(throws: VSQLError.self) { try r.get(0) as String }

        let rows = try db.cursor("SELECT v, b, l FROM foo")
        #expect(rows.columns.map(\.length) == [2000, 4, nil])
    }

    @Test func decFloatAndClob() throws {
        try db.execute("CREATE TABLE foo (d DECFLOAT, c CHARACTER LARGE OBJECT(10))")
        let want = Value.decFloat("1.5E+20")
        try db.execute("INSERT INTO foo (d, c) VALUES (?, ?)", want, "abc")
        let r = try row(db, "SELECT d, c FROM foo")
        #expect(r[0] == want)
        #expect(try r.get(0) as String == "1.5E+20")
        #expect(try r.get(0) as Double == 1.5e20)
        #expect(try r.get(0) as Decimal == Decimal(string: "1.5E+20"))
        #expect(try r.get(1) as String == "abc")
        #expect(r.columns[1].length == 10)
    }

    @Test func longStrings() throws {
        try db.execute("CREATE TABLE foo (s VARCHAR(10000))")
        for n in [255, 256, 257, 1000, 9999] {
            // Multi-byte characters cross the boundary of each piece that
            // SQLGetData reads.
            let want = String(repeating: "é", count: n / 2) + String(repeating: "x", count: n % 2)
            try db.execute("DELETE FROM foo")
            try db.execute("INSERT INTO foo (s) VALUES (?)", want)
            #expect(try db.queryValue("SELECT s FROM foo") == want, "\(n)")
        }
    }
}
