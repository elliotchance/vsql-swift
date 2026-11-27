/// An error from vsql, with its SQLSTATE (such as `"42P01"` for an undefined
/// table), message and ``Diagnostics``.
///
/// ```swift
/// do {
///     try db.execute("SELECT * FROM nope")
/// } catch let error as SQLError where error.sqlstate == "42P01" {
///     print("no such table: \(error.diagnostics.tableName ?? "")")
/// }
/// ```
public struct SQLError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The SQLSTATE, such as `"42P01"` for an undefined table. The first two
    /// characters are its class, such as `"23"` for an integrity constraint
    /// violation.
    public var sqlstate: String

    /// The message, such as `"no such table: PUBLIC.NOPE"`.
    public var message: String

    /// The constraint, table or column that the error is about.
    public var diagnostics: Diagnostics

    public init(sqlstate: String, message: String, diagnostics: Diagnostics = Diagnostics()) {
        self.sqlstate = sqlstate
        self.message = message
        self.diagnostics = diagnostics
    }

    public var description: String {
        "\(message) (SQLSTATE \(sqlstate))"
    }
}

/// The diagnostics of an ``SQLError``. Each is nil when it doesn't apply to the
/// error.
public struct Diagnostics: Hashable, Sendable {
    /// The catalog of the constraint that was violated.
    public var constraintCatalog: String?
    /// The schema of the constraint that was violated.
    public var constraintSchema: String?
    /// The name of the constraint that was violated (a constraint that wasn't
    /// named has a generated name, such as `FOO_PRIMARY_KEY`).
    public var constraintName: String?
    /// The catalog of the table.
    public var catalogName: String?
    /// The schema of the table.
    public var schemaName: String?
    /// The table, such as the one that doesn't exist, or that has the
    /// constraint that was violated.
    public var tableName: String?
    /// The column, such as the one that doesn't exist.
    public var columnName: String?
    /// The cursor, for an invalid cursor state.
    public var cursorName: String?

    public init(
        constraintCatalog: String? = nil, constraintSchema: String? = nil,
        constraintName: String? = nil, catalogName: String? = nil, schemaName: String? = nil,
        tableName: String? = nil, columnName: String? = nil, cursorName: String? = nil
    ) {
        self.constraintCatalog = constraintCatalog
        self.constraintSchema = constraintSchema
        self.constraintName = constraintName
        self.catalogName = catalogName
        self.schemaName = schemaName
        self.tableName = tableName
        self.columnName = columnName
        self.cursorName = cursorName
    }
}

/// An error from using a value or row, rather than from vsql (see
/// ``SQLError``).
public enum VSQLError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A parameter (starting at 1) can't be sent as its SQL value.
    case invalidParameter(index: Int, reason: String)

    /// There's no column at the index (starting at 0).
    case columnIndexOutOfRange(Int)

    /// There's no column with the name.
    case columnNotFound(String)

    /// The value of a column (starting at 0) can't be converted to a Swift
    /// type.
    case conversionFailed(column: Int, name: String, type: SQLType, reason: ConversionError)

    public var description: String {
        switch self {
        case .invalidParameter(let index, let reason):
            return "parameter \(index): \(reason)"
        case .columnIndexOutOfRange(let index):
            return "there's no column \(index)"
        case .columnNotFound(let name):
            return "there's no column named \(name)"
        case .conversionFailed(let column, let name, let type, let reason):
            return "column \(column) (\(name), \(type)): \(reason)"
        }
    }
}

/// Why an SQL ``Value`` can't be converted to a Swift type (see
/// ``SQLDecodable``).
public enum ConversionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The value is NULL, but the Swift type isn't an `Optional`.
    case unexpectedNull

    /// The SQL type can't be converted to the Swift type.
    case typeMismatch(expected: String, value: Value)

    /// The value is out of the range of the Swift type.
    case outOfRange(Value)

    /// Another problem with the value.
    case invalidValue(String)

    public var description: String {
        switch self {
        case .unexpectedNull:
            return "the value is NULL (read it as an Optional)"
        case .typeMismatch(let expected, let value):
            return "\(value.kindDescription) can't be converted to \(expected)"
        case .outOfRange(let value):
            return "\(value) is out of range"
        case .invalidValue(let reason):
            return reason
        }
    }
}
