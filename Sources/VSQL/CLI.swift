// CLI.swift is the only code that calls libvsql (the SQL/CLI routines in
// Sources/CVSQL/include/libvsql.h). Each function is a thin wrapper around a
// libvsql routine, with an error from the first diagnostic record of the
// handle.

import CVSQL
import Foundation

// The constants of libvsql.h, with the types that the routines take (Swift
// imports a macro as the type of its literal).
enum CLI {
    static let success = SQLRETURN(SQL_SUCCESS)
    static let successWithInfo = SQLRETURN(SQL_SUCCESS_WITH_INFO)
    static let noData = SQLRETURN(SQL_NO_DATA)
    static let invalidHandle = SQLRETURN(SQL_INVALID_HANDLE)

    static let handleEnv = SQLSMALLINT(SQL_HANDLE_ENV)
    static let handleDbc = SQLSMALLINT(SQL_HANDLE_DBC)
    static let handleStmt = SQLSMALLINT(SQL_HANDLE_STMT)
    static let handleDesc = SQLSMALLINT(SQL_HANDLE_DESC)
    static let nullHandle = SQLINTEGER(SQL_NULL_HANDLE)

    static let nullData = SQLINTEGER(SQL_NULL_DATA)
    static let nts = SQLINTEGER(SQL_NTS)
}

/// The error for a return code (SQL_NO_DATA isn't one), from the diagnostics
/// of the handle.
private func check(_ rc: SQLRETURN, _ handleType: SQLSMALLINT, _ handle: SQLINTEGER) throws {
    switch rc {
    case CLI.success, CLI.successWithInfo, CLI.noData:
        return
    case CLI.invalidHandle:
        throw SQLError(sqlstate: "HY000", message: "invalid handle")
    default:
        throw diagnostics(handleType, handle)
    }
}

/// Reads a string that's truncated if it doesn't fit in the buffer: `read` is
/// given the buffer and its size, and returns the length of the whole string
/// (which is read again with a bigger buffer if it didn't fit), or nil.
private func readString(
    capacity: Int, _ read: (UnsafeMutablePointer<SQLCHAR>, SQLSMALLINT) -> Int?
) -> String? {
    var capacity = capacity
    while true {
        var buffer = [SQLCHAR](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBufferPointer {
            read($0.baseAddress!, SQLSMALLINT(clamping: $0.count))
        }
        guard let length else {
            return nil
        }

        // The string was truncated.
        if length >= capacity {
            capacity = length + 1
            continue
        }

        return String(decoding: buffer[..<max(length, 0)], as: UTF8.self)
    }
}

/// A string field of the first diagnostic record, which is nil if it's empty
/// (or can't be read).
private func diagnosticField(
    _ handleType: SQLSMALLINT, _ handle: SQLINTEGER, _ field: Int32
) -> String? {
    let value = readString(capacity: 129) { buffer, size in
        var length: SQLSMALLINT = 0
        let rc = SQLGetDiagField(
            handleType, handle, 1, SQLSMALLINT(field), buffer, size, &length)
        guard rc == CLI.success || rc == CLI.successWithInfo else {
            return nil
        }
        return Int(length)
    }

    return value?.isEmpty == false ? value : nil
}

/// The first diagnostic record of the last routine called with a handle.
private func diagnostics(_ handleType: SQLSMALLINT, _ handle: SQLINTEGER) -> SQLError {
    vsql_swift_prepare_thread()
    var sqlstate = [SQLCHAR](repeating: 0, count: 6)
    let message = readString(capacity: 512) { buffer, size in
        var length: SQLSMALLINT = 0
        let rc = SQLGetDiagRec(
            handleType, handle, 1, &sqlstate, nil, buffer, size, &length)
        guard rc == CLI.success || rc == CLI.successWithInfo else {
            return nil
        }
        return Int(length)
    }
    guard let message else {
        return SQLError(sqlstate: "HY000", message: "unknown error")
    }

    let field = { diagnosticField(handleType, handle, $0) }
    return SQLError(
        sqlstate: String(decoding: sqlstate[..<5], as: UTF8.self),
        message: message,
        diagnostics: Diagnostics(
            constraintCatalog: field(SQL_DIAG_CONSTRAINT_CATALOG),
            constraintSchema: field(SQL_DIAG_CONSTRAINT_SCHEMA),
            constraintName: field(SQL_DIAG_CONSTRAINT_NAME),
            catalogName: field(SQL_DIAG_CATALOG_NAME),
            schemaName: field(SQL_DIAG_SCHEMA_NAME),
            tableName: field(SQL_DIAG_TABLE_NAME),
            columnName: field(SQL_DIAG_COLUMN_NAME),
            cursorName: field(SQL_DIAG_CURSOR_NAME)))
}

/// A length for libvsql, which is an error if it's too long.
private func length<T: FixedWidthInteger>(_ n: Int, _ what: String) throws -> T {
    guard let length = T(exactly: n) else {
        throw SQLError(sqlstate: "HY090", message: "the \(what) is too long")
    }
    return length
}

/// libvsql initializes itself (and its garbage collector) in the first routine
/// that's called, which isn't thread safe: another thread that calls a routine
/// at the same time can use it before it's initialized (and abort). So the
/// first routine is called once, before any other (a global is initialized
/// once, the first time it's used, even from many threads). Every connection
/// starts with allocEnv, so it's used there.
private let initialized: Bool = {
    vsql_swift_prepare_thread()
    var env: SQLHENV = 0
    if SQLAllocHandle(CLI.handleEnv, CLI.nullHandle, &env) == CLI.success {
        SQLFreeHandle(CLI.handleEnv, env)
    }
    return true
}()

func allocEnv() throws -> SQLHENV {
    vsql_swift_prepare_thread()
    _ = initialized
    var env: SQLHENV = 0
    guard SQLAllocHandle(CLI.handleEnv, CLI.nullHandle, &env) == CLI.success else {
        throw SQLError(sqlstate: "HY001", message: "can't allocate an environment")
    }
    return env
}

func allocDbc(_ env: SQLHENV) throws -> SQLHDBC {
    vsql_swift_prepare_thread()
    var dbc: SQLHDBC = 0
    try check(SQLAllocHandle(CLI.handleDbc, env, &dbc), CLI.handleEnv, env)
    return dbc
}

func allocStmt(_ dbc: SQLHDBC) throws -> SQLHSTMT {
    vsql_swift_prepare_thread()
    var stmt: SQLHSTMT = 0
    try check(SQLAllocHandle(CLI.handleStmt, dbc, &stmt), CLI.handleDbc, dbc)
    return stmt
}

func freeHandle(_ handleType: SQLSMALLINT, _ handle: SQLINTEGER) throws {
    vsql_swift_prepare_thread()
    try check(SQLFreeHandle(handleType, handle), handleType, handle)
}

/// Calls a routine with a string as SQLCHAR* and its length in octets.
private func withSQLString<T, Length: FixedWidthInteger>(
    _ s: String, _ what: String,
    _ body: (UnsafeMutablePointer<SQLCHAR>, Length) throws -> T
) throws -> T {
    var utf8 = Array(s.utf8)
    let n: Length = try length(utf8.count, what)
    if utf8.isEmpty {
        // A pointer to something, since libvsql needs one.
        utf8.append(0)
    }
    return try utf8.withUnsafeMutableBufferPointer { try body($0.baseAddress!, n) }
}

func connect(_ dbc: SQLHDBC, _ name: String) throws {
    vsql_swift_prepare_thread()
    try withSQLString(name, "database name") { (s, n: SQLSMALLINT) in
        try check(SQLConnect(dbc, s, n, nil, 0, nil, 0), CLI.handleDbc, dbc)
    }
}

func disconnect(_ dbc: SQLHDBC) throws {
    vsql_swift_prepare_thread()
    try check(SQLDisconnect(dbc), CLI.handleDbc, dbc)
}

// libvsql reads the value of SQL_ATTR_AUTOCOMMIT after SQLSetConnectAttr
// returns, so it can't be on the stack.
nonisolated(unsafe) private let autocommitOn: UnsafeMutablePointer<SQLINTEGER> = {
    let p = UnsafeMutablePointer<SQLINTEGER>.allocate(capacity: 1)
    p.initialize(to: SQLINTEGER(SQL_AUTOCOMMIT_ON))
    return p
}()

func setAutocommitOn(_ dbc: SQLHDBC) throws {
    vsql_swift_prepare_thread()
    try check(
        SQLSetConnectAttr(dbc, SQLINTEGER(SQL_ATTR_AUTOCOMMIT), autocommitOn, 0),
        CLI.handleDbc, dbc)
}

/// Reads a string from SQLGetInfo.
func getInfo(_ dbc: SQLHDBC, _ infoType: Int32) throws -> String {
    vsql_swift_prepare_thread()
    var error: SQLError?
    let value = readString(capacity: 64) { buffer, size in
        var length: SQLSMALLINT = 0
        do {
            try check(
                SQLGetInfo(dbc, SQLSMALLINT(infoType), buffer, size, &length),
                CLI.handleDbc, dbc)
        } catch let e as SQLError {
            error = e
            return nil
        } catch {
            return nil
        }
        return max(Int(length), 0)
    }
    if let error {
        throw error
    }
    return value ?? ""
}

func startTran(_ dbc: SQLHDBC, accessMode: Int, isolationLevel: Int) throws {
    vsql_swift_prepare_thread()
    try check(
        SQLStartTran(
            CLI.handleDbc, dbc, SQLINTEGER(accessMode), SQLINTEGER(isolationLevel)),
        CLI.handleDbc, dbc)
}

func endTran(_ dbc: SQLHDBC, commit: Bool) throws {
    vsql_swift_prepare_thread()
    let completion = SQLSMALLINT(commit ? SQL_COMMIT : SQL_ROLLBACK)
    try check(SQLEndTran(CLI.handleDbc, dbc, completion), CLI.handleDbc, dbc)
}

/// Rolls back to (or releases) a savepoint, which is named as it is in SQL (an
/// identifier that isn't quoted is upper case).
func endSavepoint(_ dbc: SQLHDBC, _ name: String, release: Bool) throws {
    vsql_swift_prepare_thread()
    // libvsql copies the name.
    try withSQLString(name, "savepoint name") { (s, n: SQLINTEGER) in
        try check(
            SQLSetConnectAttr(dbc, SQLINTEGER(SQL_ATTR_SAVEPOINT_NAME), s, n),
            CLI.handleDbc, dbc)
    }
    let completion = SQLSMALLINT(
        release ? SQL_SAVEPOINT_NAME_RELEASE : SQL_SAVEPOINT_NAME_ROLLBACK)
    try check(SQLEndTran(CLI.handleDbc, dbc, completion), CLI.handleDbc, dbc)
}

func execDirect(_ stmt: SQLHSTMT, _ sql: String) throws {
    vsql_swift_prepare_thread()
    try withSQLString(sql, "statement") { (s, n: SQLINTEGER) in
        try check(SQLExecDirect(stmt, s, n), CLI.handleStmt, stmt)
    }
}

func prepare(_ stmt: SQLHSTMT, _ sql: String) throws {
    vsql_swift_prepare_thread()
    try withSQLString(sql, "statement") { (s, n: SQLINTEGER) in
        try check(SQLPrepare(stmt, s, n), CLI.handleStmt, stmt)
    }
}

/// A parameter for `execute`.
struct Parameter {
    enum Data {
        case null
        case bigInt(Int64)
        case double(Double)
        case text(String)
        case binary([UInt8])
    }

    var valueType: Int32
    var parameterType: Int32
    var columnSize: Int = 0
    var decimalDigits: Int = 0
    var data: Data
}

/// Executes the prepared statement with the parameters, which are bound for
/// this execution only: they're copied to memory that lives until SQLExecute
/// returns, and then unbound so that libvsql never reads them again.
func execute(_ stmt: SQLHSTMT, _ parameters: [Parameter]) throws {
    vsql_swift_prepare_thread()
    let indicators = UnsafeMutablePointer<SQLINTEGER>.allocate(
        capacity: max(parameters.count, 1))
    var buffers: [UnsafeMutableRawPointer] = []
    defer {
        if !parameters.isEmpty {
            SQLFreeStmt(stmt, SQLSMALLINT(SQL_RESET_PARAMS))
        }
        for buffer in buffers {
            buffer.deallocate()
        }
        indicators.deallocate()
    }

    /// A copy of the bytes, with a null terminator (so that it's never empty).
    func copy(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: bytes.count + 1, alignment: 8)
        p.copyMemory(from: bytes + [0], byteCount: bytes.count + 1)
        buffers.append(p)
        return p
    }
    func copy<T>(_ value: T) -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        p.storeBytes(of: value, as: T.self)
        buffers.append(p)
        return p
    }

    for (i, parameter) in parameters.enumerated() {
        let number: SQLSMALLINT = try length(i + 1, "parameter list")
        let indicator = indicators + i
        indicator.pointee = 0
        var pointer: UnsafeMutableRawPointer? = nil
        var bufferLength: SQLINTEGER = 0
        switch parameter.data {
        case .null:
            indicator.pointee = CLI.nullData
        case .bigInt(let v):
            (pointer, bufferLength) = (copy(v), 8)
        case .double(let v):
            (pointer, bufferLength) = (copy(v), 8)
        case .text(let s):
            // libvsql needs the length of a string to be greater than zero, so
            // an empty string is a null terminated one instead.
            let utf8 = Array(s.utf8)
            pointer = copy(utf8)
            indicator.pointee = utf8.isEmpty ? CLI.nts : try length(utf8.count, "parameter")
            bufferLength = max(indicator.pointee, 0)
        case .binary(let b):
            // An empty binary string has a length of 0, which only needs a
            // pointer.
            pointer = copy(b)
            indicator.pointee = try length(b.count, "parameter")
            bufferLength = indicator.pointee
        }
        try check(
            SQLBindParameter(
                stmt, number, SQLSMALLINT(SQL_PARAM_MODE_IN),
                SQLSMALLINT(parameter.valueType), SQLSMALLINT(parameter.parameterType),
                try length(parameter.columnSize, "parameter"),
                try length(parameter.decimalDigits, "parameter"),
                pointer, bufferLength, indicator),
            CLI.handleStmt, stmt)
    }

    try check(SQLExecute(stmt), CLI.handleStmt, stmt)
}

func rowCount(_ stmt: SQLHSTMT) throws -> Int {
    vsql_swift_prepare_thread()
    var n: SQLINTEGER = 0
    try check(SQLRowCount(stmt, &n), CLI.handleStmt, stmt)
    return max(Int(n), 0)
}

/// The number of dynamic parameters of a prepared statement, which is the
/// number of records of its IPD.
func numParams(_ stmt: SQLHSTMT) throws -> Int {
    vsql_swift_prepare_thread()
    var ipd: SQLHDESC = 0
    try check(
        SQLGetStmtAttr(stmt, SQLINTEGER(SQL_ATTR_IMP_PARAM_DESC), &ipd, 0, nil),
        CLI.handleStmt, stmt)
    var n: SQLSMALLINT = 0
    try check(
        SQLGetDescField(ipd, 0, SQLSMALLINT(SQL_DESC_COUNT), &n, 0, nil),
        CLI.handleDesc, ipd)
    return max(Int(n), 0)
}

func numResultCols(_ stmt: SQLHSTMT) throws -> Int {
    vsql_swift_prepare_thread()
    var n: SQLSMALLINT = 0
    try check(SQLNumResultCols(stmt, &n), CLI.handleStmt, stmt)
    return max(Int(n), 0)
}

/// A column of a cursor, from SQLDescribeCol.
struct ColumnDescription {
    var name = ""
    var dataType: SQLSMALLINT = 0
    var columnSize: SQLINTEGER = 0
    var decimalDigits: SQLSMALLINT = 0
    var nullable: SQLSMALLINT = 0
}

/// Describes a column (starting at 1).
func describeCol(_ stmt: SQLHSTMT, _ n: Int) throws -> ColumnDescription {
    vsql_swift_prepare_thread()
    let number: SQLSMALLINT = try length(n, "column list")
    var d = ColumnDescription()
    var error: Error?
    let name = readString(capacity: 129) { buffer, size in
        var length: SQLSMALLINT = 0
        do {
            try check(
                SQLDescribeCol(
                    stmt, number, buffer, size, &length, &d.dataType, &d.columnSize,
                    &d.decimalDigits, &d.nullable),
                CLI.handleStmt, stmt)
        } catch let e {
            error = e
            return nil
        }
        return max(Int(length), 0)
    }
    if let error {
        throw error
    }
    d.name = name ?? ""
    return d
}

/// Moves to the next row, it's false after the last row.
func fetch(_ stmt: SQLHSTMT) throws -> Bool {
    vsql_swift_prepare_thread()
    let rc = SQLFetch(stmt)
    if rc == CLI.noData {
        return false
    }
    try check(rc, CLI.handleStmt, stmt)
    return true
}

func closeCursor(_ stmt: SQLHSTMT) throws {
    vsql_swift_prepare_thread()
    try check(SQLCloseCursor(stmt), CLI.handleStmt, stmt)
}

/// Reads a number column (starting at 1) of the fetched row as `T` (which is
/// targetType), it's nil for a NULL.
private func getNumber<T: Numeric>(
    _ stmt: SQLHSTMT, _ n: Int, _ targetType: Int32, _: T.Type
) throws -> T? {
    vsql_swift_prepare_thread()
    var value: T = 0
    var indicator: SQLINTEGER = 0
    let number: SQLSMALLINT = try length(n, "column list")
    let rc = withUnsafeMutableBytes(of: &value) {
        SQLGetData(
            stmt, number, SQLSMALLINT(targetType), $0.baseAddress,
            SQLINTEGER(MemoryLayout<T>.size), &indicator)
    }
    try check(rc, CLI.handleStmt, stmt)
    return indicator == CLI.nullData ? nil : value
}

func getInt64(_ stmt: SQLHSTMT, _ n: Int) throws -> Int64? {
    try getNumber(stmt, n, SQL_BIGINT, SQLBIGINT.self)
}

func getDouble(_ stmt: SQLHSTMT, _ n: Int) throws -> Double? {
    try getNumber(stmt, n, SQL_DOUBLE, SQLDOUBLE.self)
}

func getFloat(_ stmt: SQLHSTMT, _ n: Int) throws -> Float? {
    try getNumber(stmt, n, SQL_REAL, SQLREAL.self)
}

/// Reads a column (starting at 1) of the fetched row as SQL_CHAR, it's nil for
/// a NULL. A string that doesn't fit in the buffer is read in pieces.
func getString(_ stmt: SQLHSTMT, _ n: Int, _ buffer: inout [UInt8]) throws -> String? {
    vsql_swift_prepare_thread()
    let number: SQLSMALLINT = try length(n, "column list")
    if buffer.count < 256 {
        buffer = [UInt8](repeating: 0, count: 256)
    }
    var s: [UInt8] = []
    while true {
        var indicator: SQLINTEGER = 0
        let size = min(buffer.count, Int(SQLINTEGER.max))
        let rc = buffer.withUnsafeMutableBytes {
            SQLGetData(
                stmt, number, SQLSMALLINT(SQL_CHAR), $0.baseAddress, SQLINTEGER(size),
                &indicator)
        }
        try check(rc, CLI.handleStmt, stmt)
        if indicator == CLI.nullData {
            return nil
        }

        // The rest of the string (indicator) didn't fit, so the buffer has a
        // null terminated piece of it, and it grows to the size of the rest.
        let rest = Int(indicator)
        if rc == CLI.successWithInfo && rest >= size {
            let piece = buffer[..<size].firstIndex(of: 0) ?? size
            s.append(contentsOf: buffer[..<piece])
            buffer = [UInt8](repeating: 0, count: rest - piece + 1)
            continue
        }

        s.append(contentsOf: buffer[..<rest])
        guard let string = String(bytes: s, encoding: .utf8) else {
            throw SQLError(sqlstate: "22021", message: "a string isn't valid UTF-8")
        }
        return string
    }
}

/// Reads a binary string column (starting at 1) of the fetched row, it's nil
/// for a NULL. A value that doesn't fit in the buffer is read in pieces.
func getBinary(_ stmt: SQLHSTMT, _ n: Int) throws -> [UInt8]? {
    vsql_swift_prepare_thread()
    let number: SQLSMALLINT = try length(n, "column list")
    var value: [UInt8] = []
    var size = 256
    while true {
        let start = value.count
        value.append(contentsOf: repeatElement(0, count: size))
        var indicator: SQLINTEGER = 0
        let rc = value.withUnsafeMutableBytes {
            SQLGetData(
                stmt, number, SQLSMALLINT(SQL_VARBINARY), $0.baseAddress! + start,
                SQLINTEGER(size), &indicator)
        }
        try check(rc, CLI.handleStmt, stmt)
        if indicator == CLI.nullData {
            return nil
        }

        // The rest of the value (indicator) didn't fit, so the buffer is full
        // (there isn't a null terminator), and the next piece is the rest of
        // it.
        let rest = Int(indicator)
        if rc == CLI.successWithInfo && rest > size {
            size = rest - size
            continue
        }

        value.removeLast(value.count - (start + rest))
        return value
    }
}
