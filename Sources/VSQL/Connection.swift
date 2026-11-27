import CVSQL
import Foundation

/// A connection to a database, which is a file, or in memory.
///
/// ```swift
/// let db = try Connection(path: "test.vsql")
/// try db.execute("CREATE TABLE foo (x INTEGER, y VARCHAR(10))")
/// try db.execute("INSERT INTO foo (x, y) VALUES (?, ?)", 1, "a")
///
/// for row in try db.query("SELECT x, y FROM foo") {
///     let x: Int = try row.get(0)
///     let y: String = try row.get("y")
///     print(x, y)
/// }
/// ```
///
/// Each statement is committed when it finishes (or when the cursor of a query
/// is closed), unless it's in a ``transaction(isolation:readOnly:_:)``.
///
/// Each connection has its own libvsql environment, so different connections
/// can be used from different threads at the same time, but a connection (and
/// its statements and rows) must only be used by one thread at a time, so it
/// isn't `Sendable`. Connections to the same file (from any thread or process)
/// share a lock.
///
/// The connection is closed when it's no longer used (or by ``close()``),
/// which rolls back a transaction that hasn't been committed.
public final class Connection {
    private var env: SQLHENV
    private(set) var dbc: SQLHDBC
    private var inTransaction = false
    private var statements: [WeakStatement] = []

    /// Opens a database file, which is created if it doesn't exist.
    public convenience init(path: String) throws {
        try self.init(name: path)
    }

    /// Opens a database file, which is created if it doesn't exist.
    public convenience init(url: URL) throws {
        try self.init(name: url.path)
    }

    /// Opens a database that only exists in memory, for the life of the
    /// connection. Each connection to memory is a different database.
    public convenience init() throws {
        try self.init(name: ":memory:")
    }

    private init(name: String) throws {
        env = try allocEnv()
        do {
            dbc = try allocDbc(env)
        } catch {
            try? freeHandle(CLI.handleEnv, env)
            throw error
        }
        do {
            try connect(dbc, name)
        } catch {
            try? freeHandle(CLI.handleDbc, dbc)
            try? freeHandle(CLI.handleEnv, env)
            throw error
        }

        // The connection is closed (by deinit) if it fails.
        try setAutocommitOn(dbc)
    }

    deinit {
        try? close()
    }

    /// The handle of an open connection.
    func handle() throws -> SQLHDBC {
        guard dbc != CLI.nullHandle else {
            throw SQLError(sqlstate: "08003", message: "the connection is closed")
        }
        return dbc
    }

    /// Closes the connection, which rolls back a transaction that hasn't been
    /// committed. The connection (and its statements) can't be used after it's
    /// closed. Closing it again does nothing.
    public func close() throws {
        guard dbc != CLI.nullHandle else {
            return
        }

        defer { dbc = CLI.nullHandle }

        // The statements are freed first, which closes their cursors.
        for statement in statements {
            statement.value?.free()
        }
        statements = []

        var firstError: Error?
        func attempt(_ body: () throws -> Void) {
            do {
                try body()
            } catch {
                firstError = firstError ?? error
            }
        }
        if inTransaction {
            inTransaction = false
            attempt { try endTran(dbc, commit: false) }
        }
        attempt { try disconnect(dbc) }
        attempt { try freeHandle(CLI.handleDbc, dbc) }
        attempt { try freeHandle(CLI.handleEnv, env) }
        if let firstError {
            throw firstError
        }
    }

    /// Keeps a statement, so that it's freed when the connection is closed.
    func register(_ statement: Statement) {
        statements.removeAll { $0.value == nil }
        statements.append(WeakStatement(value: statement))
    }

    /// Whether each statement is committed when it finishes, which is false in a
    /// transaction.
    public var isAutocommit: Bool { !inTransaction }

    // MARK: - Statements

    /// Prepares a statement, which can be executed many times.
    public func prepare(_ sql: String) throws -> Statement {
        try Statement(self, sql: sql)
    }

    /// Executes a statement, with a `?` for each of the arguments, and returns
    /// the number of rows that it changed.
    ///
    /// ```swift
    /// try db.execute("INSERT INTO foo (x, y) VALUES (?, ?)", 1, "a")
    /// ```
    @discardableResult
    public func execute(_ sql: String, _ arguments: (any SQLEncodable)?...) throws -> Int {
        try execute(sql, arguments: arguments)
    }

    /// Executes a statement, with a `?` for each of the arguments, and returns
    /// the number of rows that it changed.
    @discardableResult
    public func execute(_ sql: String, arguments: [(any SQLEncodable)?]) throws -> Int {
        if arguments.isEmpty {
            // Without parameters, the statement doesn't need to be prepared.
            let statement = try Statement(self, sql: nil)
            try execDirect(statement.stmt, sql)
            return try statement.finishExecute()
        }

        return try prepare(sql).execute(arguments: arguments)
    }

    /// Executes a query, with a `?` for each of the arguments, and returns all
    /// of its rows.
    ///
    /// ```swift
    /// for row in try db.query("SELECT x, y FROM foo WHERE x > ?", 1) {
    ///     print(try row.get(0) as Int)
    /// }
    /// ```
    public func query(_ sql: String, _ arguments: (any SQLEncodable)?...) throws -> [Row] {
        try query(sql, arguments: arguments)
    }

    /// Executes a query, with a `?` for each of the arguments, and returns all
    /// of its rows.
    public func query(_ sql: String, arguments: [(any SQLEncodable)?]) throws -> [Row] {
        try prepare(sql).query(arguments: arguments)
    }

    /// Executes a query and decodes each row as `T` (see
    /// ``Row/decode(_:)``).
    ///
    /// ```swift
    /// struct Product: Decodable {
    ///     var id: Int
    ///     var name: String
    /// }
    ///
    /// let products = try db.query(Product.self, "SELECT id, name FROM products")
    /// ```
    public func query<T: Decodable>(
        _ type: T.Type, _ sql: String, _ arguments: (any SQLEncodable)?...
    ) throws -> [T] {
        try query(type, sql, arguments: arguments)
    }

    /// Executes a query and decodes each row as `T` (see
    /// ``Row/decode(_:)``).
    public func query<T: Decodable>(
        _ type: T.Type, _ sql: String, arguments: [(any SQLEncodable)?]
    ) throws -> [T] {
        try query(sql, arguments: arguments).map { try $0.decode(type) }
    }

    /// Executes a query and returns its first row, or nil if it has no rows.
    public func queryRow(_ sql: String, _ arguments: (any SQLEncodable)?...) throws -> Row? {
        try queryRow(sql, arguments: arguments)
    }

    /// Executes a query and returns its first row, or nil if it has no rows.
    public func queryRow(_ sql: String, arguments: [(any SQLEncodable)?]) throws -> Row? {
        try prepare(sql).queryRow(arguments: arguments)
    }

    /// Executes a query and returns the first column of its first row as `T`,
    /// or nil if it has no rows.
    ///
    /// ```swift
    /// let count: Int? = try db.queryValue("SELECT COUNT(*) FROM foo")
    /// ```
    public func queryValue<T: SQLDecodable>(
        _ sql: String, _ arguments: (any SQLEncodable)?..., as type: T.Type = T.self
    ) throws -> T? {
        try queryValue(sql, arguments: arguments, as: type)
    }

    /// Executes a query and returns the first column of its first row as `T`,
    /// or nil if it has no rows.
    public func queryValue<T: SQLDecodable>(
        _ sql: String, arguments: [(any SQLEncodable)?], as type: T.Type = T.self
    ) throws -> T? {
        try queryRow(sql, arguments: arguments)?.get(0, as: type)
    }

    /// Executes a query, and returns a cursor that reads its rows one at a
    /// time (rather than all of them).
    ///
    /// ```swift
    /// let rows = try db.cursor("SELECT x FROM foo")
    /// while let row = try rows.next() {
    ///     print(try row.get(0) as Int)
    /// }
    /// ```
    public func cursor(_ sql: String, _ arguments: (any SQLEncodable)?...) throws -> Rows {
        try cursor(sql, arguments: arguments)
    }

    /// Executes a query, and returns a cursor that reads its rows one at a
    /// time (rather than all of them).
    public func cursor(_ sql: String, arguments: [(any SQLEncodable)?]) throws -> Rows {
        try prepare(sql).cursor(arguments: arguments)
    }

    // MARK: - Transactions

    /// Runs `body` in a transaction, which is committed when it returns, or
    /// rolled back if it throws.
    ///
    /// ```swift
    /// try db.transaction { db in
    ///     try db.execute("INSERT INTO foo (x) VALUES (?)", 1)
    ///     try db.execute("INSERT INTO foo (x) VALUES (?)", 2)
    /// }
    /// ```
    ///
    /// A READ UNCOMMITTED transaction is always read only (READ WRITE can't be
    /// used with READ UNCOMMITTED), see ``IsolationLevel``. `START TRANSACTION`,
    /// `COMMIT` and `ROLLBACK` can't be executed as statements, and
    /// transactions can't be nested (see ``savepoint(_:_:)``).
    @discardableResult
    public func transaction<T>(
        isolation: IsolationLevel = .readCommitted, readOnly: Bool = false,
        _ body: (Connection) throws -> T
    ) throws -> T {
        try startTransaction(isolation: isolation, readOnly: readOnly)
        let result: T
        do {
            result = try body(self)
        } catch {
            try? endTransaction(commit: false)
            throw error
        }
        try endTransaction(commit: true)
        return result
    }

    /// Runs `body` in a savepoint, which can be rolled back to (see
    /// ``Savepoint/rollback()``) without rolling back the whole transaction.
    /// The savepoint is released when `body` returns (so its changes are part
    /// of the transaction or savepoint that it's in), or rolled back to (and
    /// released) if it throws.
    ///
    /// Outside of a transaction, the savepoint starts a transaction, which is
    /// committed when `body` returns, or rolled back if it throws.
    ///
    /// ```swift
    /// try db.transaction { db in
    ///     try db.execute("INSERT INTO foo (x) VALUES (1)")
    ///     try? db.savepoint { _ in
    ///         try db.execute("INSERT INTO foo (x) VALUES (2)")
    ///         throw CancellationError()  // Only 2 is rolled back.
    ///     }
    /// }
    /// ```
    ///
    /// `name` is the name of the savepoint (which is quoted, so it can be any
    /// string). Savepoints can be nested, and a savepoint without a name has a
    /// name for its depth.
    @discardableResult
    public func savepoint<T>(_ name: String? = nil, _ body: (Savepoint) throws -> T) throws -> T {
        let startsTransaction = !inTransaction
        if startsTransaction {
            try startTransaction(isolation: .readCommitted, readOnly: false)
        }
        savepointDepth += 1
        defer { savepointDepth -= 1 }

        let sqlName =
            name.map { "\"\($0.replacingAll("\"", with: "\"\""))\"" } ?? "VSQL_SP_\(savepointDepth)"
        do {
            try execute("SAVEPOINT \(sqlName)")
        } catch {
            if startsTransaction {
                try? endTransaction(commit: false)
            }
            throw error
        }

        let savepoint = Savepoint(connection: self, name: sqlName)
        let result: T
        do {
            result = try body(savepoint)
        } catch {
            if startsTransaction {
                try? endTransaction(commit: false)
            } else {
                try? savepoint.rollback()
                try? endSavepoint(handle(), sqlName, release: true)
            }
            throw error
        }

        if startsTransaction {
            try endTransaction(commit: true)
        } else {
            try endSavepoint(handle(), sqlName, release: true)
        }
        return result
    }

    private var savepointDepth = 0

    private func startTransaction(isolation: IsolationLevel, readOnly: Bool) throws {
        let readOnly = readOnly || isolation == .readUncommitted
        try startTran(
            handle(),
            accessMode: Int(readOnly ? SQL_TRANSACTION_READ_ONLY : SQL_TRANSACTION_READ_WRITE),
            isolationLevel: isolation.code)
        inTransaction = true
    }

    private func endTransaction(commit: Bool) throws {
        inTransaction = false
        try endTran(handle(), commit: commit)
    }
}

/// The isolation level of a transaction. vsql's transactions are READ
/// COMMITTED or SERIALIZABLE: READ UNCOMMITTED is READ COMMITTED (and read
/// only), and REPEATABLE READ is SERIALIZABLE.
public enum IsolationLevel: Hashable, Sendable, CaseIterable {
    case readUncommitted
    case readCommitted
    case repeatableRead
    case serializable

    var code: Int {
        switch self {
        case .readUncommitted: return Int(SQL_TRANSACTION_READ_UNCOMMITTED)
        case .readCommitted: return Int(SQL_TRANSACTION_READ_COMMITTED)
        case .repeatableRead: return Int(SQL_TRANSACTION_REPEATABLE_READ)
        case .serializable: return Int(SQL_TRANSACTION_SERIALIZABLE)
        }
    }
}

/// A savepoint in a transaction, see ``Connection/savepoint(_:_:)``.
public struct Savepoint {
    /// The connection of the savepoint.
    public let connection: Connection

    /// The name as it is in SQL (quoted if it was given).
    let name: String

    /// Rolls back to the savepoint, which is still active, so it can be rolled
    /// back to again.
    public func rollback() throws {
        try endSavepoint(connection.handle(), name, release: false)
    }
}

private struct WeakStatement {
    weak var value: Statement?
}
