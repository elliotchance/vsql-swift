// Decoding a row as a Decodable type, see Row.decode.

extension Row {
    /// Decodes the row as `T`, with a column for each property (the column
    /// names are matched ignoring ASCII case, since a name that isn't quoted is
    /// upper case). Each property is decoded as an ``SQLDecodable`` (or as any
    /// `Decodable` that's decoded from a single value, such as a `String` or
    /// `Int` enum), and an `Optional` property is nil for NULL (or a column
    /// that isn't in the row).
    ///
    /// ```swift
    /// struct Product: Decodable {
    ///     var id: Int
    ///     var name: String
    ///     var price: Decimal?
    /// }
    ///
    /// let row = try db.queryRow("SELECT id, name, price FROM products")!
    /// let product = try row.decode(Product.self)
    /// ```
    ///
    /// A type that's decoded from a single value (such as `Int`) is the first
    /// column, and an unkeyed container is the columns in order.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try T(from: RowDecoder(row: self))
    }
}

/// The DecodingError for a value that can't be converted.
private func conversionError(
    _ type: Any.Type, _ error: Error, _ codingPath: [any CodingKey]
) -> DecodingError {
    if case VSQLError.conversionFailed(_, _, _, .unexpectedNull) = error {
        return .valueNotFound(
            type,
            .init(codingPath: codingPath, debugDescription: "\(error)", underlyingError: error))
    }
    return .typeMismatch(
        type, .init(codingPath: codingPath, debugDescription: "\(error)", underlyingError: error))
}

struct IndexKey: CodingKey {
    var intValue: Int?
    var stringValue: String

    init(_ index: Int) {
        intValue = index
        stringValue = "\(index)"
    }

    init?(intValue: Int) { self.init(intValue) }
    init?(stringValue: String) { nil }
}

private struct RowDecoder: Decoder {
    let row: Row
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(KeyedContainer(row: row))
    }

    func unkeyedContainer() -> any UnkeyedDecodingContainer {
        UnkeyedContainer(row: row)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        guard !row.isEmpty else {
            throw DecodingError.valueNotFound(
                Value.self,
                .init(codingPath: [], debugDescription: "the row doesn't have any columns"))
        }
        return ValueDecoder(row: row, index: 0, codingPath: [])
    }
}

/// Decodes the value of a column.
private func decodeColumn<T: Decodable>(
    _ type: T.Type, _ row: Row, _ index: Int, _ codingPath: [any CodingKey]
) throws -> T {
    if let decodable = type as? any SQLDecodable.Type {
        do {
            return try row.get(index, as: decodable) as! T
        } catch {
            throw conversionError(type, error, codingPath)
        }
    }
    return try T(from: ValueDecoder(row: row, index: index, codingPath: codingPath))
}

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: Row
    var codingPath: [any CodingKey] { [] }

    var allKeys: [Key] {
        row.columns.compactMap { Key(stringValue: $0.name) }
    }

    func contains(_ key: Key) -> Bool {
        row.columnIndex(key.stringValue) != nil
    }

    private func index(_ key: Key) throws -> Int {
        guard let index = row.columnIndex(key.stringValue) else {
            throw DecodingError.keyNotFound(
                key,
                .init(
                    codingPath: [],
                    debugDescription: "there's no column named \(key.stringValue)"))
        }
        return index
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        row[try index(key)] == .null
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try decodeColumn(type, row, try index(key), [key])
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch(
            type, .init(codingPath: [key], debugDescription: "a column is a single value"))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self, .init(codingPath: [key], debugDescription: "a column is a single value"))
    }

    func superDecoder() throws -> any Decoder { RowDecoder(row: row) }
    func superDecoder(forKey key: Key) throws -> any Decoder { RowDecoder(row: row) }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let row: Row
    var currentIndex = 0
    var codingPath: [any CodingKey] { [] }
    var count: Int? { row.count }
    var isAtEnd: Bool { currentIndex >= row.count }

    init(row: Row) {
        self.row = row
    }

    private mutating func next() throws -> Int {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                Value.self,
                .init(
                    codingPath: [IndexKey(currentIndex)],
                    debugDescription: "there are only \(row.count) columns"))
        }
        defer { currentIndex += 1 }
        return currentIndex
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, row[currentIndex] == .null else {
            return false
        }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let index = try next()
        return try decodeColumn(type, row, index, [IndexKey(index)])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch(
            type, .init(codingPath: codingPath, debugDescription: "a column is a single value"))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(codingPath: codingPath, debugDescription: "a column is a single value"))
    }

    mutating func superDecoder() throws -> any Decoder { RowDecoder(row: row) }
}

/// Decodes the value of one column, for a Decodable that isn't an
/// SQLDecodable (such as a RawRepresentable enum).
private struct ValueDecoder: Decoder, SingleValueDecodingContainer {
    let row: Row
    let index: Int
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.typeMismatch(
            type, .init(codingPath: codingPath, debugDescription: "a column is a single value"))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(codingPath: codingPath, debugDescription: "a column is a single value"))
    }

    func singleValueContainer() -> any SingleValueDecodingContainer { self }

    func decodeNil() -> Bool { row[index] == .null }

    private func get<T: SQLDecodable>(_ type: T.Type) throws -> T {
        do {
            return try row.get(index, as: type)
        } catch {
            throw conversionError(type, error, codingPath)
        }
    }

    func decode(_ type: Bool.Type) throws -> Bool { try get(type) }
    func decode(_ type: String.Type) throws -> String { try get(type) }
    func decode(_ type: Double.Type) throws -> Double { try get(type) }
    func decode(_ type: Float.Type) throws -> Float { try get(type) }
    func decode(_ type: Int.Type) throws -> Int { try get(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try get(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try get(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try get(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try get(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try get(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try get(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try get(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try get(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try get(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try decodeColumn(type, row, index, codingPath)
    }
}
