import CVSQL

/// A prepared statement, see ``Connection/prepare(_:)``. It can be executed
/// many times, with different arguments.
///
/// ```swift
/// let insert = try db.prepare("INSERT INTO foo (x) VALUES (?)")
/// for x in 1...10 {
///     try insert.execute(x)
/// }
/// ```
public final class Statement {
    /// The connection of the statement.
    public let connection: Connection

    private(set) var stmt: SQLHSTMT

    /// The rows of the last query, which are closed before the statement is
    /// executed again.
    private weak var openRows: Rows?

    init(_ connection: Connection, sql: String?) throws {
        self.connection = connection
        stmt = try allocStmt(connection.handle())
        connection.register(self)
        if let sql {
            // The statement is freed (by deinit) if it fails.
            try prepare(stmt, sql)
        }
    }

    deinit {
        free()
    }

    /// Frees the statement's handle, which is done before its connection is
    /// closed.
    func free() {
        guard stmt != CLI.nullHandle else {
            return
        }
        openRows?.markClosed()
        try? freeHandle(CLI.handleStmt, stmt)
        stmt = CLI.nullHandle
    }

    /// The handle of a statement that hasn't been freed (by closing its
    /// connection).
    private func handle() throws -> SQLHSTMT {
        guard stmt != CLI.nullHandle else {
            throw SQLError(sqlstate: "08003", message: "the connection is closed")
        }
        return stmt
    }

    /// The number of parameters (`?`) of the statement.
    public var parameterCount: Int {
        (try? numParams(handle())) ?? 0
    }

    /// Executes the statement, with a `?` for each of the arguments, and
    /// returns the number of rows that it changed.
    @discardableResult
    public func execute(_ arguments: (any SQLEncodable)?...) throws -> Int {
        try execute(arguments: arguments)
    }

    /// Executes the statement, with a `?` for each of the arguments, and
    /// returns the number of rows that it changed.
    @discardableResult
    public func execute(arguments: [(any SQLEncodable)?]) throws -> Int {
        try run(arguments)
        return try finishExecute()
    }

    /// Executes the query, with a `?` for each of the arguments, and returns
    /// all of its rows.
    public func query(_ arguments: (any SQLEncodable)?...) throws -> [Row] {
        try query(arguments: arguments)
    }

    /// Executes the query, with a `?` for each of the arguments, and returns
    /// all of its rows.
    public func query(arguments: [(any SQLEncodable)?]) throws -> [Row] {
        let rows = try cursor(arguments: arguments)
        var all: [Row] = []
        while let row = try rows.next() {
            all.append(row)
        }
        return all
    }

    /// Executes the query and returns its first row, or nil if it has no rows.
    public func queryRow(_ arguments: (any SQLEncodable)?...) throws -> Row? {
        try queryRow(arguments: arguments)
    }

    /// Executes the query and returns its first row, or nil if it has no rows.
    public func queryRow(arguments: [(any SQLEncodable)?]) throws -> Row? {
        let rows = try cursor(arguments: arguments)
        defer { try? rows.close() }
        return try rows.next()
    }

    /// Executes the query, with a `?` for each of the arguments, and returns a
    /// cursor that reads its rows one at a time. Executing the statement again
    /// closes the cursor.
    public func cursor(_ arguments: (any SQLEncodable)?...) throws -> Rows {
        try cursor(arguments: arguments)
    }

    /// Executes the query, with a `?` for each of the arguments, and returns a
    /// cursor that reads its rows one at a time. Executing the statement again
    /// closes the cursor.
    public func cursor(arguments: [(any SQLEncodable)?]) throws -> Rows {
        try run(arguments)
        let rows = try Rows(self)
        openRows = rows
        return rows
    }

    private func run(_ arguments: [(any SQLEncodable)?]) throws {
        try openRows?.close()
        openRows = nil
        let stmt = try handle()

        var parameters: [Parameter] = []
        parameters.reserveCapacity(arguments.count)
        for (i, argument) in arguments.enumerated() {
            let value: Value
            do {
                value = try argument?.sqlValue() ?? .null
            } catch let error as ConversionError {
                throw VSQLError.invalidParameter(index: i + 1, reason: error.description)
            }
            parameters.append(try value.parameter(i + 1))
        }

        try VSQL.execute(stmt, parameters)
    }

    /// The number of rows that the statement changed, after closing the cursor
    /// if it was a query.
    func finishExecute() throws -> Int {
        let stmt = try handle()
        let n = try rowCount(stmt)
        if try numResultCols(stmt) > 0 {
            try closeCursor(stmt)
        }
        return n
    }
}

/// A column of a query's rows.
public struct Column: Hashable, Sendable {
    /// The name of the column. Names that weren't quoted are upper case.
    public let name: String

    /// The SQL type of the column.
    public let type: SQLType

    /// Whether the column can be NULL.
    public let isNullable: Bool

    let size: Int
    let digits: Int

    /// The maximum number of characters of a CHARACTER, CHARACTER VARYING or
    /// CHARACTER LARGE OBJECT, or octets of a BINARY, BINARY VARYING or BINARY
    /// LARGE OBJECT, which is nil for any other type (or a large object without
    /// a length).
    public var length: Int? {
        // A large object without a length has the largest size.
        guard size > 0, size != Int(Int32.max) else {
            return nil
        }
        switch type {
        // The size is in octets, with 4 for each character.
        case .character, .characterVarying, .characterLargeObject:
            return size / 4
        case .binary, .binaryVarying, .binaryLargeObject:
            return size
        default:
            return nil
        }
    }

    /// The precision of a DECIMAL or NUMERIC.
    public var precision: Int? {
        type == .decimal || type == .numeric ? size : nil
    }

    /// The scale of a DECIMAL or NUMERIC.
    public var scale: Int? {
        type == .decimal || type == .numeric ? digits : nil
    }
}

/// The rows of a query, read one at a time, see ``Statement/cursor(_:)``.
///
/// The cursor is closed after the last row, when it's no longer used, or by
/// ``close()``. A query is committed when its cursor is closed (unless it's in
/// a transaction).
public final class Rows {
    private let statement: Statement

    /// The columns of the rows.
    public let columns: [Column]

    private let kinds: [Value.Kind]
    private var buffer: [UInt8] = []
    private var isOpen = true

    init(_ statement: Statement) throws {
        self.statement = statement
        let stmt = statement.stmt
        do {
            let n = try numResultCols(stmt)
            var columns: [Column] = []
            for i in 1...max(n, 1) where n > 0 {
                let d = try describeCol(stmt, i)
                columns.append(
                    Column(
                        name: d.name, type: SQLType(code: d.dataType),
                        isNullable: d.nullable != SQL_NO_NULLS, size: Int(d.columnSize),
                        digits: Int(d.decimalDigits)))
            }
            self.columns = columns
        } catch {
            try? closeCursor(stmt)
            throw error
        }
        kinds = columns.map { Value.Kind($0.type) }
    }

    deinit {
        try? close()
    }

    /// The names of the columns.
    public var columnNames: [String] {
        columns.map(\.name)
    }

    /// The next row, or nil after the last row.
    public func next() throws -> Row? {
        guard isOpen else {
            return nil
        }
        do {
            let stmt = statement.stmt
            guard try fetch(stmt) else {
                try close()
                return nil
            }

            var values: [Value] = []
            values.reserveCapacity(columns.count)
            for (i, (column, kind)) in zip(columns, kinds).enumerated() {
                let n = i + 1
                let value: Value?
                switch kind {
                case .integer: value = try getInt64(stmt, n).map(Value.integer)
                case .double: value = try getDouble(stmt, n).map(Value.double)
                case .real: value = try getFloat(stmt, n).map { .double(Double($0)) }
                case .binary: value = try getBinary(stmt, n).map(Value.binary)
                case .text:
                    value = try getString(stmt, n, &buffer).map {
                        try Value.parse($0, column: column, index: i)
                    }
                }
                values.append(value ?? .null)
            }

            return Row(columns: columns, values: values)
        } catch {
            // The rows end after an error.
            try? close()
            throw error
        }
    }

    /// Closes the cursor. Closing it again does nothing.
    public func close() throws {
        guard isOpen else {
            return
        }
        isOpen = false
        try closeCursor(statement.stmt)
    }

    /// The cursor was closed by freeing its statement.
    func markClosed() {
        isOpen = false
    }
}

/// A row of a query. It's a collection of the values of its columns, which can
/// also be read by name, or as a Swift type with ``get(_:as:)-5yz6c``.
public struct Row: RandomAccessCollection, Hashable, Sendable {
    /// The columns of the row.
    public let columns: [Column]

    /// The values of the columns.
    public let values: [Value]

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }

    /// The value of a column (starting at 0).
    public subscript(index: Int) -> Value {
        values[index]
    }

    /// The value of the column with the name (ignoring ASCII case), or nil if
    /// there's no column with the name.
    public subscript(name: String) -> Value? {
        columnIndex(name).map { values[$0] }
    }

    /// The names of the columns.
    public var columnNames: [String] {
        columns.map(\.name)
    }

    /// The index of the column with the name (ignoring ASCII case).
    public func columnIndex(_ name: String) -> Int? {
        columns.firstIndex { $0.name.equalsIgnoringASCIICase(name) }
    }

    /// The value of a column (starting at 0) as `T`. NULL is only a `T` that's
    /// an `Optional`.
    ///
    /// ```swift
    /// let row = try db.queryRow("VALUES ROW(1, CAST(NULL AS INTEGER))")!
    /// let x: Int = try row.get(0)
    /// let y: Int? = try row.get(1)
    /// ```
    public func get<T: SQLDecodable>(_ index: Int, as type: T.Type = T.self) throws -> T {
        guard values.indices.contains(index) else {
            throw VSQLError.columnIndexOutOfRange(index)
        }
        do {
            return try T(sqlValue: values[index])
        } catch let error as ConversionError {
            let column = columns[index]
            throw VSQLError.conversionFailed(
                column: index, name: column.name, type: column.type, reason: error)
        }
    }

    /// The value of the column with the name (ignoring ASCII case) as `T`.
    /// NULL is only a `T` that's an `Optional`.
    public func get<T: SQLDecodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        guard let index = columnIndex(name) else {
            throw VSQLError.columnNotFound(name)
        }
        return try get(index, as: type)
    }
}

extension String {
    func equalsIgnoringASCIICase(_ other: String) -> Bool {
        func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        return utf8.count == other.utf8.count
            && zip(utf8, other.utf8).allSatisfy { lower($0) == lower($1) }
    }
}
