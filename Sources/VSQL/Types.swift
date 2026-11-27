import CVSQL

/// An SQL type, from a column's description (see ``Column/type``).
public enum SQLType: Hashable, Sendable, CustomStringConvertible {
    case smallInt
    case integer
    case bigInt
    case real
    case doublePrecision
    case decimal
    case numeric
    case decFloat
    case character
    case characterVarying
    case characterLargeObject
    case binary
    case binaryVarying
    case binaryLargeObject
    case boolean
    case date
    case time
    case timeWithTimeZone
    case timestamp
    case timestampWithTimeZone
    /// An INTERVAL, such as INTERVAL YEAR TO MONTH.
    case interval(IntervalFields)
    /// A data type code that isn't known.
    case other(Int16)

    init(code: Int16) {
        switch Int32(code) {
        case SQL_SMALLINT: self = .smallInt
        case SQL_INTEGER: self = .integer
        case SQL_BIGINT: self = .bigInt
        case SQL_REAL: self = .real
        case SQL_FLOAT, SQL_DOUBLE: self = .doublePrecision
        case SQL_DECIMAL: self = .decimal
        case SQL_NUMERIC: self = .numeric
        case SQL_DECFLOAT: self = .decFloat
        case SQL_CHAR: self = .character
        case SQL_VARCHAR: self = .characterVarying
        case SQL_CLOB: self = .characterLargeObject
        case SQL_BINARY: self = .binary
        case SQL_VARBINARY: self = .binaryVarying
        case SQL_BLOB: self = .binaryLargeObject
        case SQL_BOOLEAN: self = .boolean
        case SQL_TYPE_DATE: self = .date
        case SQL_TYPE_TIME: self = .time
        case SQL_TYPE_TIME_WITH_TIMEZONE: self = .timeWithTimeZone
        case SQL_TYPE_TIMESTAMP: self = .timestamp
        case SQL_TYPE_TIMESTAMP_WITH_TIMEZONE: self = .timestampWithTimeZone
        default:
            if let fields = IntervalFields(code: code) {
                self = .interval(fields)
            } else {
                self = .other(code)
            }
        }
    }

    /// The SQL name of the type, such as `"CHARACTER VARYING"`.
    public var name: String {
        switch self {
        case .smallInt: return "SMALLINT"
        case .integer: return "INTEGER"
        case .bigInt: return "BIGINT"
        case .real: return "REAL"
        case .doublePrecision: return "DOUBLE PRECISION"
        case .decimal: return "DECIMAL"
        case .numeric: return "NUMERIC"
        case .decFloat: return "DECFLOAT"
        case .character: return "CHARACTER"
        case .characterVarying: return "CHARACTER VARYING"
        case .characterLargeObject: return "CHARACTER LARGE OBJECT"
        case .binary: return "BINARY"
        case .binaryVarying: return "BINARY VARYING"
        case .binaryLargeObject: return "BINARY LARGE OBJECT"
        case .boolean: return "BOOLEAN"
        case .date: return "DATE"
        case .time: return "TIME"
        case .timeWithTimeZone: return "TIME WITH TIME ZONE"
        case .timestamp: return "TIMESTAMP"
        case .timestampWithTimeZone: return "TIMESTAMP WITH TIME ZONE"
        case .interval(let fields): return "INTERVAL \(fields)"
        case .other: return "UNKNOWN"
        }
    }

    public var description: String { name }
}

/// A DATE.
public struct SQLDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (a: SQLDate, b: SQLDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Such as `2022-01-02`.
    public var description: String {
        "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }
}

/// A TIME, or a TIME WITH TIME ZONE if it has an offset.
public struct SQLTime: Hashable, Sendable, Codable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int
    public var second: Int
    public var microsecond: Int
    /// The offset from UTC in minutes (east is positive), for a TIME WITH TIME
    /// ZONE.
    public var offset: Int?

    public init(hour: Int, minute: Int, second: Int, microsecond: Int = 0, offset: Int? = nil) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
        self.offset = offset
    }

    /// The time with microseconds, and the offset as `+HH:MM`, such as
    /// `15:04:05.123456+05:30`.
    public var description: String {
        var s = "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2)).\(pad(microsecond, 6))"
        if let offset {
            s += "\(offset < 0 ? "-" : "+")\(pad(abs(offset) / 60, 2)):\(pad(abs(offset) % 60, 2))"
        }
        return s
    }
}

/// A TIMESTAMP, or a TIMESTAMP WITH TIME ZONE if its time has an offset.
public struct SQLTimestamp: Hashable, Sendable, Codable, CustomStringConvertible {
    public var date: SQLDate
    public var time: SQLTime

    public init(date: SQLDate, time: SQLTime) {
        self.date = date
        self.time = time
    }

    /// Such as `2022-01-02 15:04:05.123456+05:30`.
    public var description: String { "\(date) \(time)" }
}

/// The fields of an INTERVAL type, such as YEAR TO MONTH.
public enum IntervalFields: Hashable, Sendable, CaseIterable, Codable, CustomStringConvertible {
    case year
    case month
    case day
    case hour
    case minute
    case second
    case yearToMonth
    case dayToHour
    case dayToMinute
    case dayToSecond
    case hourToMinute
    case hourToSecond
    case minuteToSecond

    init?(code: Int16) {
        switch Int32(code) {
        case SQL_INTERVAL_YEAR: self = .year
        case SQL_INTERVAL_MONTH: self = .month
        case SQL_INTERVAL_DAY: self = .day
        case SQL_INTERVAL_HOUR: self = .hour
        case SQL_INTERVAL_MINUTE: self = .minute
        case SQL_INTERVAL_SECOND: self = .second
        case SQL_INTERVAL_YEAR_TO_MONTH: self = .yearToMonth
        case SQL_INTERVAL_DAY_TO_HOUR: self = .dayToHour
        case SQL_INTERVAL_DAY_TO_MINUTE: self = .dayToMinute
        case SQL_INTERVAL_DAY_TO_SECOND: self = .dayToSecond
        case SQL_INTERVAL_HOUR_TO_MINUTE: self = .hourToMinute
        case SQL_INTERVAL_HOUR_TO_SECOND: self = .hourToSecond
        case SQL_INTERVAL_MINUTE_TO_SECOND: self = .minuteToSecond
        default: return nil
        }
    }

    /// Whether it's a year-month interval (YEAR, MONTH or YEAR TO MONTH),
    /// otherwise it's a day-time interval.
    public var isYearMonth: Bool {
        self == .year || self == .month || self == .yearToMonth
    }

    /// The first and last field.
    fileprivate var range: (first: Field, last: Field) {
        switch self {
        case .year: return (.year, .year)
        case .month: return (.month, .month)
        case .day: return (.day, .day)
        case .hour: return (.hour, .hour)
        case .minute: return (.minute, .minute)
        case .second: return (.second, .second)
        case .yearToMonth: return (.year, .month)
        case .dayToHour: return (.day, .hour)
        case .dayToMinute: return (.day, .minute)
        case .dayToSecond: return (.day, .second)
        case .hourToMinute: return (.hour, .minute)
        case .hourToSecond: return (.hour, .second)
        case .minuteToSecond: return (.minute, .second)
        }
    }

    /// The fields from the first to the last.
    fileprivate var fields: [Field] {
        let (first, last) = range
        return Field.allCases.filter { $0 >= first && $0 <= last }
    }

    /// Such as `"YEAR TO MONTH"`.
    public var description: String {
        let (first, last) = range
        return first == last ? first.name : "\(first.name) TO \(last.name)"
    }
}

/// A field of an interval.
private enum Field: Int, Comparable, CaseIterable {
    case year, month, day, hour, minute, second

    static func < (a: Field, b: Field) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .year: return "YEAR"
        case .month: return "MONTH"
        case .day: return "DAY"
        case .hour: return "HOUR"
        case .minute: return "MINUTE"
        case .second: return "SECOND"
        }
    }

    /// The size of the field in months (YEAR and MONTH) or microseconds.
    var size: UInt64 {
        switch self {
        case .year: return 12
        case .month: return 1
        case .day: return 86_400_000_000
        case .hour: return 3_600_000_000
        case .minute: return 60_000_000
        case .second: return 1_000_000
        }
    }

    /// The separator before the field, when it isn't the first.
    var separator: Character {
        switch self {
        case .month: return "-"
        case .hour: return " "
        default: return ":"
        }
    }
}

/// An INTERVAL. A year-month interval (see ``IntervalFields/isYearMonth``) is a
/// number of months, and a day-time interval is a number of microseconds.
/// They're negative for a negative interval.
///
/// ```swift
/// let i: SQLInterval = try db.queryValue("VALUES INTERVAL '-1-02' YEAR TO MONTH")!
/// // SQLInterval(fields: .yearToMonth, months: -14)
/// print(i) // INTERVAL '-1-02' YEAR(2) TO MONTH
/// ```
public struct SQLInterval: Hashable, Sendable, Codable, CustomStringConvertible {
    public var fields: IntervalFields
    /// The months of a year-month interval (a multiple of 12 for YEAR), or 0.
    public var months: Int64
    /// The microseconds of a day-time interval, or 0. The fields that aren't in
    /// the interval are left out (so 1.5 days is 1 day as an INTERVAL DAY).
    public var microseconds: Int64

    public init(fields: IntervalFields, months: Int64 = 0, microseconds: Int64 = 0) {
        self.fields = fields
        self.months = months
        self.microseconds = microseconds
    }

    /// The interval as a literal, such as `INTERVAL '-1-02' YEAR(2) TO MONTH`.
    /// The first field has the precision it needs (at least 2), and seconds
    /// have 6 fractional digits.
    public var description: String {
        let (first, last) = fields.range
        let value = fields.isYearMonth ? months : microseconds
        var rest = value.magnitude
        let leading = rest / first.size
        rest %= first.size
        var s = "INTERVAL '\(value < 0 ? "-" : "")\(leading)"
        for field in fields.fields.dropFirst() {
            s += "\(field.separator)\(pad(Int(rest / field.size), 2))"
            rest %= field.size
        }
        if last == .second {
            s += ".\(pad(Int(rest), 6))"
        }

        s += "' \(first.name)(\(max(String(leading).count, 2))"
        if first == .second {
            s += ", 6"
        }
        s += ")"
        if last != first {
            s += " TO \(last.name)"
            if last == .second {
                s += "(6)"
            }
        }
        return s
    }
}

/// An SQL value. A value that's read is the `Value` of the column's type, and
/// a parameter (see ``SQLEncodable``) is sent as the SQL type of its `Value`,
/// which is cast to the type it's used as.
///
/// A `Value` can be written as a literal, such as `nil`, `1`, `1.5`, `true` or
/// `"a"`.
public enum Value: Hashable, Sendable, Codable {
    /// NULL.
    case null
    /// A BOOLEAN.
    case boolean(Bool)
    /// A SMALLINT, INTEGER or BIGINT (a parameter is a BIGINT).
    case integer(Int64)
    /// A REAL or DOUBLE PRECISION (a parameter is a DOUBLE PRECISION).
    case double(Double)
    /// A DECIMAL or NUMERIC, which is exact, as a decimal string such as
    /// `"-1.25"` (a parameter is a NUMERIC).
    case numeric(String)
    /// A DECFLOAT, which is exact, as a decimal string that may have an
    /// exponent, such as `"-1.25"` or `"1.5E+20"`.
    case decFloat(String)
    /// A CHARACTER, CHARACTER VARYING or CHARACTER LARGE OBJECT (a parameter
    /// is a CHARACTER VARYING).
    case text(String)
    /// A BINARY, BINARY VARYING or BINARY LARGE OBJECT (a parameter is a
    /// BINARY VARYING).
    case binary([UInt8])
    /// A DATE.
    case date(SQLDate)
    /// A TIME (WITH TIME ZONE).
    case time(SQLTime)
    /// A TIMESTAMP (WITH TIME ZONE).
    case timestamp(SQLTimestamp)
    /// An INTERVAL.
    case interval(SQLInterval)

    /// Whether the value is NULL.
    public var isNull: Bool { self == .null }

    /// What the value is, for errors.
    var kindDescription: String {
        switch self {
        case .null: return "NULL"
        case .boolean: return "a BOOLEAN"
        case .integer: return "an integer"
        case .double: return "a DOUBLE PRECISION"
        case .numeric: return "a NUMERIC"
        case .decFloat: return "a DECFLOAT"
        case .text: return "a string"
        case .binary: return "a binary string"
        case .date: return "a DATE"
        case .time: return "a TIME"
        case .timestamp: return "a TIMESTAMP"
        case .interval: return "an INTERVAL"
        }
    }
}

extension Value: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .text(value) }
}

extension Value: CustomStringConvertible {
    /// The value, such as `NULL`, `TRUE`, `12`, `'a'`, `X'00FF'` or
    /// `DATE '2022-01-02'`.
    public var description: String {
        switch self {
        case .null: return "NULL"
        case .boolean(let b): return b ? "TRUE" : "FALSE"
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .numeric(let s), .decFloat(let s): return s
        case .text(let s): return "'\(s.replacingAll("'", with: "''"))'"
        case .binary(let b):
            let hex = b.map { pad(Int($0), 2, radix: 16) }.joined().uppercased()
            return "X'\(hex)'"
        case .date(let d): return "DATE '\(d)'"
        case .time(let t): return "TIME '\(t)'"
        case .timestamp(let t): return "TIMESTAMP '\(t)'"
        case .interval(let i): return i.description
        }
    }
}

// MARK: - Reading and binding values

extension Value {
    /// How a column of the type is read with SQLGetData.
    enum Kind {
        case integer, double, real, text, binary

        init(_ type: SQLType) {
            switch type {
            case .smallInt, .integer, .bigInt: self = .integer
            case .real: self = .real
            case .doublePrecision: self = .double
            case .binary, .binaryVarying, .binaryLargeObject: self = .binary
            default: self = .text
            }
        }
    }

    /// The value of a column (starting at 0) that's read as a string.
    static func parse(_ s: String, column: Column, index: Int) throws -> Value {
        let type = column.type
        let invalid = VSQLError.conversionFailed(
            column: index, name: column.name, type: type,
            reason: .invalidValue("invalid \(type): \(s)"))
        switch type {
        case .boolean:
            switch s {
            case "TRUE": return .boolean(true)
            case "FALSE": return .boolean(false)
            default: throw invalid
            }
        case .decimal, .numeric:
            return .numeric(s)
        case .decFloat:
            return .decFloat(s)
        case .interval(let fields):
            guard let i = parseInterval(s, fields) else { throw invalid }
            return .interval(i)
        case .date:
            guard let d = literal(s, "DATE").flatMap(parseDate) else { throw invalid }
            return .date(d)
        case .time, .timeWithTimeZone:
            guard let t = literal(s, "TIME").flatMap(parseTime) else { throw invalid }
            return .time(t)
        case .timestamp, .timestampWithTimeZone:
            guard let t = literal(s, "TIMESTAMP").flatMap(parseTimestamp) else {
                throw invalid
            }
            return .timestamp(t)
        default:
            return .text(s)
        }
    }

    /// The parameter (starting at 1) for this value.
    func parameter(_ index: Int) throws -> Parameter {
        func text(_ type: Int32, _ size: Int, _ digits: Int, _ s: String) -> Parameter {
            Parameter(
                valueType: SQL_CHAR, parameterType: type, columnSize: size,
                decimalDigits: digits, data: .text(s))
        }

        switch self {
        // The type doesn't matter for a NULL, since it's cast to the type it's
        // used as.
        case .null:
            return Parameter(
                valueType: SQL_CHAR, parameterType: SQL_VARCHAR, columnSize: 1, data: .null)
        case .boolean(let b):
            return text(SQL_BOOLEAN, 0, 0, b ? "TRUE" : "FALSE")
        case .integer(let i):
            return Parameter(valueType: SQL_BIGINT, parameterType: SQL_BIGINT, data: .bigInt(i))
        case .double(let d):
            return Parameter(valueType: SQL_DOUBLE, parameterType: SQL_DOUBLE, data: .double(d))
        case .numeric(let s):
            // A NUMERIC with the precision of the digits. vsql counts at least
            // one digit before the decimal point (so 0.25 is NUMERIC(3, 2)).
            let unsigned = s.hasPrefix("-") ? s.dropFirst() : Substring(s)
            let parts = unsigned.split(
                separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let integer = parts[0]
            let fraction = parts.count > 1 ? parts[1] : ""
            let isDigits = { (p: Substring) in p.allSatisfy { $0.isASCII && $0.isNumber } }
            guard !integer.isEmpty, isDigits(integer), isDigits(fraction) else {
                throw VSQLError.invalidParameter(
                    index: index, reason: "\"\(s)\" isn't a decimal number")
            }
            let integerDigits = max(integer.drop { $0 == "0" }.count, 1)
            return text(SQL_NUMERIC, integerDigits + fraction.count, fraction.count, s)
        // 34 is the precision of a DECFLOAT, and vsql checks the string.
        case .decFloat(let s):
            return text(SQL_DECFLOAT, 34, 0, s)
        case .text(let s):
            // A CHARACTER VARYING as long as the string (which can't be 0).
            return text(SQL_VARCHAR, max(s.unicodeScalars.count, 1), 0, s)
        case .binary(let b):
            // A BINARY VARYING as long as the value (which can't be 0).
            return Parameter(
                valueType: SQL_VARBINARY, parameterType: SQL_VARBINARY,
                columnSize: max(b.count, 1), data: .binary(b))
        case .date(let d):
            let s = d.description
            return text(SQL_TYPE_DATE, s.utf8.count, 0, s)
        case .time(let t):
            let s = t.description
            let type = t.offset == nil ? SQL_TYPE_TIME : SQL_TYPE_TIME_WITH_TIMEZONE
            return text(type, s.utf8.count, 6, s)
        case .timestamp(let t):
            let s = t.description
            let type =
                t.time.offset == nil ? SQL_TYPE_TIMESTAMP : SQL_TYPE_TIMESTAMP_WITH_TIMEZONE
            return text(type, s.utf8.count, 6, s)
        // The literal is cast to the parameter's interval type.
        case .interval(let i):
            let s = i.description
            return text(SQL_VARCHAR, s.utf8.count, 0, s)
        }
    }
}

// The datetimes from SQLGetData are literals, such as
// "TIMESTAMP '2022-01-02 15:04:05.123456+05:30'". There are at most 6
// fractional digits.

/// The value of a literal, such as "2022-01-02" for "DATE '2022-01-02'".
private func literal(_ s: String, _ keyword: String) -> Substring? {
    let prefix = keyword + " '"
    guard s.hasPrefix(prefix), s.hasSuffix("'"), s.count > prefix.count else { return nil }
    return s.dropFirst(prefix.count).dropLast()
}

/// A number of exactly n digits (or any number of digits for nil).
private func digits(_ s: Substring, _ n: Int? = nil) -> Int? {
    guard !s.isEmpty, n == nil || s.count == n!, s.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return Int(s)
}

private func parseDate(_ s: Substring) -> SQLDate? {
    let parts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = digits(parts[0], 4), let month = digits(parts[1], 2),
        let day = digits(parts[2], 2)
    else { return nil }
    return SQLDate(year: year, month: month, day: day)
}

private func parseTime(_ s: Substring) -> SQLTime? {
    var s = s
    // The offset is "+HH:MM" or "-HH:MM".
    var offset: Int?
    if let i = s.firstIndex(where: { $0 == "+" || $0 == "-" }) {
        let sign = s[i]
        let parts = s[s.index(after: i)...].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hh = digits(parts[0], 2), let mm = digits(parts[1], 2) else {
            return nil
        }
        offset = (hh * 60 + mm) * (sign == "-" ? -1 : 1)
        s = s[..<i]
    }
    var microsecond = 0
    if let dot = s.firstIndex(of: ".") {
        let fraction = s[s.index(after: dot)...]
        guard (1...6).contains(fraction.count), let f = digits(fraction, fraction.count) else {
            return nil
        }
        microsecond = f * Int(pow10(6 - fraction.count))
        s = s[..<dot]
    }
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, let hour = digits(parts[0], 2), let minute = digits(parts[1], 2),
        let second = digits(parts[2], 2)
    else { return nil }
    return SQLTime(
        hour: hour, minute: minute, second: second, microsecond: microsecond, offset: offset)
}

private func parseTimestamp(_ s: Substring) -> SQLTimestamp? {
    guard let space = s.firstIndex(of: " "), let date = parseDate(s[..<space]),
        let time = parseTime(s[s.index(after: space)...])
    else { return nil }
    return SQLTimestamp(date: date, time: time)
}

/// An interval literal, such as "INTERVAL '-1-02' YEAR(2) TO MONTH", which has
/// the fields of its type.
private func parseInterval(_ s: String, _ fields: IntervalFields) -> SQLInterval? {
    let prefix = "INTERVAL '"
    guard s.hasPrefix(prefix) else { return nil }
    let afterPrefix = s.dropFirst(prefix.count)
    guard let quote = afterPrefix.firstIndex(of: "'") else { return nil }
    var rest = afterPrefix[..<quote]
    let negative = rest.hasPrefix("-")
    if negative {
        rest = rest.dropFirst()
    }

    let all = fields.fields
    var total: UInt64 = 0
    for (i, field) in all.enumerated() {
        var part = rest
        if i + 1 < all.count {
            guard let separator = rest.firstIndex(of: all[i + 1].separator) else { return nil }
            part = rest[..<separator]
            rest = rest[rest.index(after: separator)...]
        }
        var fraction: UInt64 = 0
        if let dot = part.firstIndex(of: ".") {
            let digitsAfter = part[part.index(after: dot)...]
            guard field == .second, digitsAfter.count <= 6,
                let f = digits(digitsAfter)
            else { return nil }
            fraction = UInt64(f) * pow10(6 - digitsAfter.count)
            part = part[..<dot]
        }
        guard let n = digits(part) else { return nil }
        let (product, o1) = UInt64(n).multipliedReportingOverflow(by: field.size)
        let (sum, o2) = total.addingReportingOverflow(product)
        let (withFraction, o3) = sum.addingReportingOverflow(fraction)
        guard !o1, !o2, !o3 else { return nil }
        total = withFraction
    }

    guard let magnitude = Int64(exactly: total) else { return nil }
    let value = negative ? -magnitude : magnitude
    return fields.isYearMonth
        ? SQLInterval(fields: fields, months: value)
        : SQLInterval(fields: fields, microseconds: value)
}

private func pow10(_ n: Int) -> UInt64 {
    (0..<n).reduce(1) { r, _ in r * 10 }
}

/// A number with leading zeros, such as "05" for pad(5, 2).
func pad(_ n: Int, _ width: Int, radix: Int = 10) -> String {
    let s = String(n, radix: radix)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}

extension String {
    func replacingAll(_ target: Character, with replacement: String) -> String {
        var s = ""
        for c in self {
            if c == target {
                s += replacement
            } else {
                s.append(c)
            }
        }
        return s
    }
}
