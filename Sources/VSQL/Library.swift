import CVSQL

/// The version of vsql (libvsql) that's compiled into the package, and how it
/// was built.
///
/// ```swift
/// print(VSQLLibrary.version) // "1.8.2"
/// let info = VSQLLibrary.buildInfo
/// print("vsql \(info.version) (\(info.date)) built with V \(info.vVersion)")
/// ```
public enum VSQLLibrary {
    /// The version of vsql, such as `"1.8.2"`.
    public static var version: String { loaded.version }

    /// The version of vsql as a number, such as `1008002` for 1.8.2.
    public static var versionNumber: Int { loaded.number }

    /// How libvsql was built.
    public static var buildInfo: BuildInfo { loaded.build }

    private static let loaded: (version: String, number: Int, build: BuildInfo) = {
        do {
            return try load()
        } catch {
            fatalError("can't read the version of libvsql: \(error)")
        }
    }()

    private static func load() throws -> (version: String, number: Int, build: BuildInfo) {
        let db = try Connection()
        let dbc = try db.handle()
        let info = { try getInfo(dbc, $0) }

        // SQL_DBMS_VERSION is "01.08.0002" for 1.8.2.
        let dbmsVersion = try info(SQL_DBMS_VERSION)
        let parts = dbmsVersion.split(separator: ".").compactMap { Int($0) }
        var (version, number) = (dbmsVersion, 0)
        if parts.count == 3 {
            version = "\(parts[0]).\(parts[1]).\(parts[2])"
            number = parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2]
        }

        let build = BuildInfo(
            version: try info(SQL_VSQL_BUILD_VERSION),
            commit: try info(SQL_VSQL_BUILD_COMMIT),
            date: try info(SQL_VSQL_BUILD_DATE),
            vVersion: try info(SQL_VSQL_BUILD_V_VERSION),
            vCommit: try info(SQL_VSQL_BUILD_V_COMMIT),
            cCompiler: try info(SQL_VSQL_BUILD_C_COMPILER),
            operatingSystem: try info(SQL_VSQL_OPERATING_SYSTEM),
            machine: try info(SQL_VSQL_MACHINE))
        return (version, number, build)
    }
}

/// How libvsql was built, see ``VSQLLibrary/buildInfo``.
public struct BuildInfo: Hashable, Sendable {
    /// The vsql release, such as `"v1.8.2"` (empty if it isn't a release).
    public let version: String
    /// The git commit of the release (empty if it isn't a release).
    public let commit: String
    /// The date it was built, such as `"2026-11-12"` (UTC).
    public let date: String
    /// The version of V that compiled vsql to C, such as `"0.5.2"`.
    public let vVersion: String
    /// The git commit of V.
    public let vCommit: String
    /// The C compiler that V used, such as `"clang"`.
    public let cCompiler: String
    /// The operating system, such as `"macos"`.
    public let operatingSystem: String
    /// The machine, such as `"arm64"`.
    public let machine: String
}
