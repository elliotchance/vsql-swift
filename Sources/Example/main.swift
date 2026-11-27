// A complete program that uses vsql:
//
//   swift run Example

import Foundation
import VSQL

struct Product: Decodable {
    var name: String
    var price: Decimal?
    var added: SQLDate?
}

let db = try Connection()
try db.execute(
    """
    CREATE TABLE products (
        id INTEGER NOT NULL,
        name VARCHAR(50) NOT NULL,
        price NUMERIC(10, 2),
        added DATE)
    """)

try db.transaction { db in
    let insert = try db.prepare("INSERT INTO products (id, name, price, added) VALUES (?, ?, ?, ?)")
    try insert.execute(1, "Bolt", Decimal(string: "0.25"), SQLDate(year: 2024, month: 1, day: 2))
    try insert.execute(2, "Nut", Decimal(string: "0.10"), SQLDate(year: 2024, month: 3, day: 4))
    try insert.execute(3, "Washer", nil, nil)
}

let rows = try db.cursor("SELECT name, price, added FROM products WHERE id > ? ORDER BY id", 1)
print(rows.columnNames)
while let row = try rows.next() {
    let product = try row.decode(Product.self)
    print(
        product.name, product.price.map { "\($0)" } ?? "NULL",
        product.added.map { "\($0)" } ?? "NULL")
}

do {
    try db.execute("SELECT * FROM nope")
} catch let error as SQLError {
    print("\(error.sqlstate): \(error)")
}
