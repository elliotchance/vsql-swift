import Foundation

/// A type that can be a parameter, which is sent as the SQL type of its
/// ``Value`` (and cast to the type that it's used as).
///
/// | Swift                                       | SQL                                         |
/// |---------------------------------------------|---------------------------------------------|
/// | `nil`                                       | `NULL`                                      |
/// | `Bool`                                      | `BOOLEAN`                                   |
/// | `Int`, `Int8` to `Int64`, `UInt8` to `UInt32` | `BIGINT`                                  |
/// | `UInt`, `UInt64`                            | `BIGINT` (`NUMERIC` if it's out of range)   |
/// | `Double`, `Float`                           | `DOUBLE PRECISION`                          |
/// | `Decimal`                                   | `NUMERIC`                                   |
/// | `String`, `Substring`                       | `CHARACTER VARYING`                         |
/// | `[UInt8]`, `Data`                           | `BINARY VARYING`                            |
/// | ``SQLDate``                                 | `DATE`                                      |
/// | ``SQLTime``                                 | `TIME(6)` (`WITH TIME ZONE` with an offset) |
/// | ``SQLTimestamp``                            | `TIMESTAMP(6)` (`WITH TIME ZONE` with an offset) |
/// | `Date`                                      | `TIMESTAMP(6) WITH TIME ZONE` (in UTC)      |
/// | ``SQLInterval``                             | the `INTERVAL` literal                      |
///
/// A `DECFLOAT` is a ``Value/decFloat(_:)``.
public protocol SQLEncodable {
    /// The SQL value.
    func sqlValue() throws -> Value
}

/// A type that a column can be read as (see ``Row/get(_:as:)-5yz6c``).
///
/// | SQL                              | Swift                                       |
/// |----------------------------------|---------------------------------------------|
/// | `SMALLINT`, `INTEGER`, `BIGINT`  | any integer type (if it's in range)         |
/// | `REAL`, `DOUBLE PRECISION`       | `Double`, `Float`                           |
/// | `DECIMAL`, `NUMERIC`, `DECFLOAT` | `String` (exact), `Decimal`, `Double`       |
/// | `CHARACTER`, `VARCHAR`, `CLOB`   | `String`                                    |
/// | `BINARY`, `VARBINARY`, `BLOB`    | `[UInt8]`, `Data`                           |
/// | `BOOLEAN`                        | `Bool`                                      |
/// | `DATE`                           | ``SQLDate``                                 |
/// | `TIME (WITH TIME ZONE)`          | ``SQLTime``                                 |
/// | `TIMESTAMP (WITH TIME ZONE)`     | ``SQLTimestamp``, `Date`                    |
/// | `INTERVAL ...`                   | ``SQLInterval``                             |
///
/// A NULL is only an `Optional`. Any column can be read as a ``Value``.
public protocol SQLDecodable {
    /// The Swift value of an SQL value, or a ``ConversionError``.
    init(sqlValue: Value) throws
}

/// A type that's both ``SQLEncodable`` and ``SQLDecodable``.
public typealias SQLCodable = SQLEncodable & SQLDecodable

func mismatch<T>(_ value: Value, _: T.Type) -> ConversionError {
    value == .null ? .unexpectedNull : .typeMismatch(expected: "\(T.self)", value: value)
}

extension Value: SQLCodable {
    public func sqlValue() -> Value { self }
    public init(sqlValue: Value) { self = sqlValue }
}

extension Optional: SQLEncodable where Wrapped: SQLEncodable {
    public func sqlValue() throws -> Value {
        try self?.sqlValue() ?? .null
    }
}

/// NULL is nil, otherwise it's the value as `Wrapped`.
extension Optional: SQLDecodable where Wrapped: SQLDecodable {
    public init(sqlValue: Value) throws {
        self = sqlValue == .null ? nil : try Wrapped(sqlValue: sqlValue)
    }
}

extension Bool: SQLCodable {
    public func sqlValue() -> Value { .boolean(self) }

    public init(sqlValue: Value) throws {
        guard case .boolean(let b) = sqlValue else { throw mismatch(sqlValue, Bool.self) }
        self = b
    }
}

extension SQLEncodable where Self: BinaryInteger {
    /// A BIGINT, or a NUMERIC if it's out of range.
    public func sqlValue() -> Value {
        Int64(exactly: self).map(Value.integer) ?? .numeric(String(self))
    }
}

extension SQLDecodable where Self: FixedWidthInteger {
    /// A SMALLINT, INTEGER or BIGINT that's in range.
    public init(sqlValue: Value) throws {
        guard case .integer(let i) = sqlValue else { throw mismatch(sqlValue, Self.self) }
        guard let value = Self(exactly: i) else { throw ConversionError.outOfRange(sqlValue) }
        self = value
    }
}

extension Int: SQLCodable {}
extension Int8: SQLCodable {}
extension Int16: SQLCodable {}
extension Int32: SQLCodable {}
extension Int64: SQLCodable {}
extension UInt: SQLCodable {}
extension UInt8: SQLCodable {}
extension UInt16: SQLCodable {}
extension UInt32: SQLCodable {}
extension UInt64: SQLCodable {}

/// A REAL or DOUBLE PRECISION, an integer, or a DECIMAL, NUMERIC or DECFLOAT
/// (which may lose precision).
extension Double: SQLCodable {
    public func sqlValue() -> Value { .double(self) }

    public init(sqlValue: Value) throws {
        switch sqlValue {
        case .double(let d):
            self = d
        case .integer(let i):
            self = Double(i)
        case .numeric(let s), .decFloat(let s):
            guard let d = Double(s) else {
                throw ConversionError.invalidValue("\(s) isn't a number")
            }
            self = d
        default:
            throw mismatch(sqlValue, Double.self)
        }
    }
}

/// See `Double`.
extension Float: SQLCodable {
    public func sqlValue() -> Value { .double(Double(self)) }

    public init(sqlValue: Value) throws {
        self = Float(try Double(sqlValue: sqlValue))
    }
}

/// A CHARACTER, CHARACTER VARYING or CHARACTER LARGE OBJECT, or a DECIMAL,
/// NUMERIC or DECFLOAT (as its exact decimal string).
extension String: SQLCodable {
    public func sqlValue() -> Value { .text(self) }

    public init(sqlValue: Value) throws {
        switch sqlValue {
        case .text(let s), .numeric(let s), .decFloat(let s):
            self = s
        default:
            throw mismatch(sqlValue, String.self)
        }
    }
}

extension Substring: SQLEncodable {
    public func sqlValue() -> Value { .text(String(self)) }
}

/// A BINARY, BINARY VARYING or BINARY LARGE OBJECT.
extension Array: SQLEncodable where Element == UInt8 {
    public func sqlValue() -> Value { .binary(self) }
}

extension Array: SQLDecodable where Element == UInt8 {
    public init(sqlValue: Value) throws {
        guard case .binary(let b) = sqlValue else { throw mismatch(sqlValue, [UInt8].self) }
        self = b
    }
}

/// A BINARY, BINARY VARYING or BINARY LARGE OBJECT.
extension Data: SQLCodable {
    public func sqlValue() -> Value { .binary([UInt8](self)) }

    public init(sqlValue: Value) throws {
        guard case .binary(let b) = sqlValue else { throw mismatch(sqlValue, Data.self) }
        self = Data(b)
    }
}

/// A NUMERIC, or a DECIMAL, NUMERIC, DECFLOAT or integer.
extension Decimal: SQLCodable {
    public func sqlValue() throws -> Value {
        guard isFinite else {
            throw ConversionError.invalidValue("\(self) isn't a finite number")
        }
        return .numeric(description)
    }

    public init(sqlValue: Value) throws {
        switch sqlValue {
        case .integer(let i):
            self = Decimal(i)
        case .numeric(let s), .decFloat(let s):
            guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else {
                throw ConversionError.invalidValue("\(s) isn't a decimal number")
            }
            self = d
        default:
            throw mismatch(sqlValue, Decimal.self)
        }
    }
}

extension SQLDate: SQLCodable {
    public func sqlValue() -> Value { .date(self) }

    public init(sqlValue: Value) throws {
        guard case .date(let d) = sqlValue else { throw mismatch(sqlValue, SQLDate.self) }
        self = d
    }
}

extension SQLTime: SQLCodable {
    public func sqlValue() -> Value { .time(self) }

    public init(sqlValue: Value) throws {
        guard case .time(let t) = sqlValue else { throw mismatch(sqlValue, SQLTime.self) }
        self = t
    }
}

extension SQLTimestamp: SQLCodable {
    public func sqlValue() -> Value { .timestamp(self) }

    public init(sqlValue: Value) throws {
        guard case .timestamp(let t) = sqlValue else {
            throw mismatch(sqlValue, SQLTimestamp.self)
        }
        self = t
    }
}

extension SQLInterval: SQLCodable {
    public func sqlValue() -> Value { .interval(self) }

    public init(sqlValue: Value) throws {
        guard case .interval(let i) = sqlValue else { throw mismatch(sqlValue, SQLInterval.self) }
        self = i
    }
}

// MARK: - Foundation dates

/// The days since 1970-01-01 of a date in the proleptic Gregorian calendar
/// (from Howard Hinnant's days_from_civil).
private func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

/// The date of a number of days since 1970-01-01 (civil_from_days).
private func civilFromDays(_ days: Int) -> SQLDate {
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    return SQLDate(year: yoe + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
}

extension SQLTimestamp {
    /// The timestamp of a `Date`, to the microsecond, with an offset from UTC
    /// in minutes (east is positive), or nil for a TIMESTAMP without a time
    /// zone (in UTC).
    public init(_ date: Date, offset: Int? = 0) {
        let micros =
            Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
            + Int64(offset ?? 0) * 60_000_000
        let perDay: Int64 = 86_400_000_000
        let days = micros >= 0 ? micros / perDay : (micros - perDay + 1) / perDay
        var rest = Int(micros - days * perDay)
        let hour = rest / 3_600_000_000
        rest %= 3_600_000_000
        let minute = rest / 60_000_000
        rest %= 60_000_000
        self.init(
            date: civilFromDays(Int(days)),
            time: SQLTime(
                hour: hour, minute: minute, second: rest / 1_000_000,
                microsecond: rest % 1_000_000, offset: offset))
    }

    /// The `Date` of the timestamp. A TIMESTAMP without a time zone is in UTC.
    public var foundationDate: Date {
        let days = daysFromCivil(date.year, date.month, date.day)
        let seconds =
            Int64(days) * 86400 + Int64(time.hour * 3600 + time.minute * 60 + time.second)
            - Int64(time.offset ?? 0) * 60
        return Date(
            timeIntervalSince1970: Double(seconds) + Double(time.microsecond) / 1_000_000)
    }
}

/// A TIMESTAMP WITH TIME ZONE (in UTC) as a parameter, and a TIMESTAMP (WITH
/// TIME ZONE) as a column. A TIMESTAMP without a time zone is in UTC.
extension Date: SQLCodable {
    public func sqlValue() -> Value { .timestamp(SQLTimestamp(self)) }

    public init(sqlValue: Value) throws {
        guard case .timestamp(let t) = sqlValue else { throw mismatch(sqlValue, Date.self) }
        self = t.foundationDate
    }
}
