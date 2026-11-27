# vsql-swift

A Swift package for [vsql](https://github.com/elliotchance/vsql), a single file
or in-memory SQL database. libvsql (the vsql library) is compiled into the
package, so there's nothing else to install.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/elliotchance/vsql-swift", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "VSQL", package: "vsql-swift")]),
]
```

```swift
import VSQL

let db = try Connection(path: "test.vsql")
try db.execute("CREATE TABLE foo (x INTEGER, y VARCHAR(10))")
try db.execute("INSERT INTO foo (x, y) VALUES (?, ?)", 1, "a")

for row in try db.query("SELECT x, y FROM foo") {
    let x: Int = try row.get(0)
    let y: String = try row.get("y")
    print(x, y)
}
```

`Connection(path:)` (or `Connection(url:)`) creates the file if it doesn't
exist, and `Connection()` is a database that only exists in memory for the
life of the connection. Each `?` is an argument, which is any `SQLEncodable`
(or `nil`).

See [Sources/Example/main.swift](Sources/Example/main.swift) for a complete
program:

```sh
swift run Example
```

## Queries

- `execute` runs a statement and returns the number of rows that it changed.
- `query` returns all of the rows, `queryRow` the first row (or `nil`), and
  `queryValue` the first column of the first row:

  ```swift
  let count: Int? = try db.queryValue("SELECT COUNT(*) FROM foo")
  ```

- `cursor` reads the rows one at a time:

  ```swift
  let rows = try db.cursor("SELECT x FROM foo WHERE x > ?", 1)
  while let row = try rows.next() {
      print(try row.get(0) as Int)
  }
  ```

- `prepare` returns a `Statement`, which can be executed many times (with the
  same methods).

A `Row` is a collection of `Value`s (`row[0]`, or `row["y"]` by name), and
`row.get` reads a column as a Swift type. Names that weren't quoted in SQL are
upper case, so they're matched ignoring ASCII case.

## Decodable

A row can be decoded as any `Decodable`, with a column for each property:

```swift
struct Product: Decodable {
    var id: Int
    var name: String
    var price: Decimal?
}

let products = try db.query(Product.self, "SELECT id, name, price FROM products")
let product = try db.queryRow("SELECT * FROM products")?.decode(Product.self)
```

An `Optional` property is `nil` for `NULL`. `RawRepresentable` enums work too,
and a type such as `Int` is decoded from the first column
(`try db.query(Int.self, "SELECT id FROM products")`).

## Transactions

Each statement is committed when it finishes (or when the cursor of a query
is closed), unless it's in a transaction, which is committed when the closure
returns, or rolled back if it throws:

```swift
try db.transaction { db in
    try db.execute("INSERT INTO foo (x) VALUES (?)", 2)
    try db.execute("INSERT INTO foo (x) VALUES (?)", 3)
}
```

Transactions are `READ COMMITTED` unless another isolation level (or a read
only transaction) is given with
`db.transaction(isolation: .serializable, readOnly: true)`. vsql's transactions
are `READ COMMITTED` or `SERIALIZABLE`: `READ UNCOMMITTED` is `READ COMMITTED`
(and read only), and `REPEATABLE READ` is `SERIALIZABLE`.

A savepoint can be rolled back to without rolling back the whole transaction.
It's released when its closure returns, or rolled back to if it throws:

```swift
try db.transaction { db in
    try db.execute("INSERT INTO foo (x) VALUES (?)", 3)
    try db.savepoint { savepoint in
        try db.execute("INSERT INTO foo (x) VALUES (?)", 4)
        try savepoint.rollback() // Undoes 4, the savepoint is still active.
        try db.execute("INSERT INTO foo (x) VALUES (?)", 5)
    }
} // 3 and 5.
```

Savepoints can be nested (and named, with `db.savepoint("name")`). A savepoint
outside of a transaction starts one, which is committed when it's released.

## Types

| SQL                              | Swift                                       |
|----------------------------------|---------------------------------------------|
| `SMALLINT`, `INTEGER`, `BIGINT`  | any integer type (if it's in range)         |
| `REAL`, `DOUBLE PRECISION`       | `Double`, `Float`                           |
| `DECIMAL`, `NUMERIC`, `DECFLOAT` | `String` (exact), `Decimal`, `Double`       |
| `CHARACTER`, `VARCHAR`, `CLOB`   | `String`                                    |
| `BINARY`, `VARBINARY`, `BLOB`    | `[UInt8]`, `Data`                           |
| `BOOLEAN`                        | `Bool`                                      |
| `DATE`                           | `SQLDate`                                   |
| `TIME (WITH TIME ZONE)`          | `SQLTime`                                   |
| `TIMESTAMP (WITH TIME ZONE)`     | `SQLTimestamp`, `Date`                      |
| `INTERVAL ...`                   | `SQLInterval`                               |

A `NULL` is only an `Optional`, and any column can be read as a `Value`.
Arguments are sent as the SQL type of their `Value` (such as `BIGINT` for an
`Int`, or `TIMESTAMP(6) WITH TIME ZONE` in UTC for a `Date`), which is cast to
the type that they're used as. A `DECFLOAT` argument is a
`Value.decFloat("1.5E+20")`.

A `Date` is an instant, so a `TIMESTAMP` without a time zone is read as UTC.
`SQLTimestamp(date, offset: minutes)` is a `Date` in another time zone (or
without one, with `offset: nil`).

An `SQLInterval` is a number of months (`YEAR`, `MONTH` or `YEAR TO MONTH`) or
microseconds (the other fields):

```swift
let i: SQLInterval? = try db.queryValue("VALUES INTERVAL '1 2' DAY TO HOUR")
print(i!.microseconds) // 93600000000
print(i!)              // INTERVAL '1 02' DAY(2) TO HOUR
```

Your own types can be arguments and columns by conforming to `SQLEncodable`
and `SQLDecodable`.

## Errors

An error from vsql is an `SQLError`, with its SQLSTATE:

```swift
do {
    try db.execute("SELECT * FROM nope")
} catch let error as SQLError where error.sqlstate == "42P01" {
    print("no such table")
}
```

`error.diagnostics` has the constraint, table or column that the error is
about (such as `diagnostics.constraintName`). Other errors, such as a column
that can't be read as a Swift type, are a `VSQLError`.

## Version

`VSQLLibrary.version` is the version of vsql that's compiled into the package
(such as `"1.8.2"`), and `VSQLLibrary.buildInfo` has how it was built.

## Threads

Each connection has its own libvsql environment, so different connections can
be used from different threads (or tasks) at the same time. A `Connection`
(and its statements and rows) must only be used by one thread at a time, so it
isn't `Sendable`: open a connection for each thread or task. Connections to
the same file share a lock.

## Requirements

Swift 6.0 or later, on macOS 13 or later (ARM64 and x86-64), Linux (ARM64 and
x86-64) or Windows (x86-64). iOS and the other Apple platforms aren't
supported yet. The first build compiles libvsql, which takes about 15 seconds
(or a couple of minutes with optimizations).

## Testing

```sh
swift test
```

The tests cover every line of `Sources/VSQL`, which CI checks with:

```sh
swift test --enable-code-coverage
swift scripts/check-coverage.swift "$(swift test --show-codecov-path)"
```

It lists the lines that aren't covered. Code that a test can't reach should be
restructured (or removed) rather than left out.

## Updating vsql

`Sources/CVSQL` has the libvsql C from a vsql release
(`vsql-VERSION-amalgamation.zip`). To update it to the latest release:

```sh
scripts/update-amalgamation.sh
swift test
```

Or give a version (`scripts/update-amalgamation.sh v1.2.3`), or a zip that has
already been downloaded. The script checks that `Package.swift` links the same
libraries as the amalgamation.

## Releasing

Swift packages aren't uploaded anywhere: Swift Package Manager clones the git
repository, and a version is a git tag. To release, publish a GitHub release
with a semantic version tag (such as `v1.0.1`) on a commit of `main` that
passed CI. Users get it with `from: "1.0.0"` (up to the next major version).

The package can be added to the [Swift Package Index](https://swiftpackageindex.com)
(once), which finds new tags itself and builds the documentation
(`.spi.yml`).
