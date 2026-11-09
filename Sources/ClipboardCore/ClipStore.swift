import CryptoKit
import Foundation

public enum ClipStoreError: Error, Equatable, LocalizedError {
    case emptyName

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A collection needs a name."
        }
    }
}

/// Clipboard history on disk: an index in the SQLite that ships with macOS,
/// and images as separate files named by the hash of their content.
///
/// Images are files, not database rows, so the index stays small and an image
/// is in memory only while it is shown.
public final class ClipStore {
    /// Which items a list shows.
    public enum Scope: Hashable, Sendable {
        case history
        case collection(Int64)
    }

    /// Copies larger than this are not recorded.
    public static let maxItemBytes = 50 * 1024 * 1024
    /// History not saved in a collection is removed after this many days.
    public static let historyDays = 90

    public let directory: URL
    private let imagesDirectory: URL
    private let database: SQLiteDatabase

    public init(directory: URL) throws {
        self.directory = directory
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("clipboard.sqlite").path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, image_file TEXT,
                width INTEGER NOT NULL, height INTEGER NOT NULL, bytes INTEGER NOT NULL, source_app TEXT,
                created REAL NOT NULL, last_copied REAL NOT NULL, hash TEXT NOT NULL UNIQUE)
            """)
        try database.execute(
            "CREATE TABLE IF NOT EXISTS collections (id INTEGER PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL)")
        try database.execute("""
            CREATE TABLE IF NOT EXISTS collection_items (
                collection_id INTEGER NOT NULL, item_id INTEGER NOT NULL, added REAL NOT NULL,
                PRIMARY KEY (collection_id, item_id))
            """)
    }

    /// The default location: Application Support/QuickShot/Clipboard.
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("QuickShot/Clipboard", isDirectory: true)
    }

    // MARK: Items

    /// Stores one copy. The same content copied again updates the existing
    /// item's time instead of adding a second one. Returns `nil` for a copy
    /// over the size limit or with nothing in it.
    @discardableResult
    public func record(_ candidate: ClipCandidate, at date: Date = Date()) throws -> ClipItem? {
        let size = candidate.byteCount
        guard size > 0, size <= Self.maxItemBytes else { return nil }
        let hash = Self.hash(candidate)
        let now = date.timeIntervalSince1970

        if let existing = try items(where: "hash = ?", [.text(hash)]).first {
            try database.execute("UPDATE items SET last_copied = ? WHERE id = ?", [.real(now), .int(existing.id)])
            return try item(id: existing.id)
        }

        var imageFile: String?
        if candidate.kind == .image, let data = candidate.imageData {
            let name = "\(hash).png"
            try data.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            imageFile = name
        }
        try database.execute("""
            INSERT INTO items (kind, text, image_file, width, height, bytes, source_app, created, last_copied, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(candidate.kind.rawValue), .text(candidate.text), imageFile.map(SQLiteValue.text) ?? .null,
                .int(Int64(candidate.pixelWidth)), .int(Int64(candidate.pixelHeight)), .int(Int64(size)),
                candidate.sourceApp.map(SQLiteValue.text) ?? .null, .real(now), .real(now), .text(hash),
            ])
        return try item(id: database.lastInsertedRowID)
    }

    public func item(id: Int64) throws -> ClipItem? {
        try items(where: "id = ?", [.int(id)]).first
    }

    /// Items in a scope, most recently copied first. `search` is a plain
    /// substring match on the stored text, ignoring letter case.
    public func items(in scope: Scope, matching search: String = "") throws -> [ClipItem] {
        var conditions: [String] = []
        var values: [SQLiteValue] = []
        if case .collection(let id) = scope {
            conditions.append("id IN (SELECT item_id FROM collection_items WHERE collection_id = ?)")
            values.append(.int(id))
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            conditions.append(#"text LIKE ? ESCAPE '\'"#)
            let escaped = query.replacingOccurrences(of: #"\"#, with: #"\\"#)
                .replacingOccurrences(of: "%", with: #"\%"#)
                .replacingOccurrences(of: "_", with: #"\_"#)
            values.append(.text("%\(escaped)%"))
        }
        return try items(where: conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values)
    }

    /// Removes an item from history and from every collection.
    public func delete(_ item: ClipItem) throws {
        try database.execute("DELETE FROM collection_items WHERE item_id = ?", [.int(item.id)])
        try database.execute("DELETE FROM items WHERE id = ?", [.int(item.id)])
        if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
    }

    public func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDirectory.appendingPathComponent($0) }
    }

    /// Removes history older than `days` that is not saved in any collection.
    /// Returns how many items were removed.
    @discardableResult
    public func expire(olderThan days: Int = ClipStore.historyDays, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let stale = try items(
            where: "last_copied < ? AND id NOT IN (SELECT item_id FROM collection_items)", [.real(cutoff)])
        for item in stale { try delete(item) }
        return stale.count
    }

    // MARK: Collections

    public func collections() throws -> [ClipCollection] {
        try database.query("SELECT id, name FROM collections ORDER BY name COLLATE NOCASE, id") { row in
            ClipCollection(id: row.int(0), name: row.text(1) ?? "")
        }
    }

    @discardableResult
    public func createCollection(named name: String, at date: Date = Date()) throws -> ClipCollection {
        let trimmed = try Self.validated(name)
        try database.execute("INSERT INTO collections (name, created) VALUES (?, ?)",
                             [.text(trimmed), .real(date.timeIntervalSince1970)])
        return ClipCollection(id: database.lastInsertedRowID, name: trimmed)
    }

    public func renameCollection(_ collection: ClipCollection, to name: String) throws {
        try database.execute("UPDATE collections SET name = ? WHERE id = ?",
                             [.text(try Self.validated(name)), .int(collection.id)])
    }

    /// Deletes the collection. Its items stay in history.
    public func deleteCollection(_ collection: ClipCollection) throws {
        try database.execute("DELETE FROM collection_items WHERE collection_id = ?", [.int(collection.id)])
        try database.execute("DELETE FROM collections WHERE id = ?", [.int(collection.id)])
    }

    public func add(_ item: ClipItem, to collection: ClipCollection, at date: Date = Date()) throws {
        try database.execute("INSERT OR IGNORE INTO collection_items (collection_id, item_id, added) VALUES (?, ?, ?)",
                             [.int(collection.id), .int(item.id), .real(date.timeIntervalSince1970)])
    }

    public func remove(_ item: ClipItem, from collection: ClipCollection) throws {
        try database.execute("DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?",
                             [.int(collection.id), .int(item.id)])
    }

    /// The ids of the collections that hold an item.
    public func collectionIDs(containing item: ClipItem) throws -> Set<Int64> {
        Set(try database.query("SELECT collection_id FROM collection_items WHERE item_id = ?", [.int(item.id)]) {
            $0.int(0)
        })
    }

    // MARK: Private

    private func items(where condition: String, _ values: [SQLiteValue]) throws -> [ClipItem] {
        try database.query("""
            SELECT id, kind, text, image_file, width, height, bytes, source_app, created, last_copied
            FROM items WHERE \(condition) ORDER BY last_copied DESC, id DESC
            """, values) { row in
            ClipItem(
                id: row.int(0), kind: ClipKind(rawValue: row.text(1) ?? "") ?? .text, text: row.text(2) ?? "",
                imageFile: row.text(3), pixelWidth: Int(row.int(4)), pixelHeight: Int(row.int(5)),
                byteCount: Int(row.int(6)), sourceApp: row.text(7),
                created: Date(timeIntervalSince1970: row.real(8)), lastCopied: Date(timeIntervalSince1970: row.real(9)))
        }
    }

    private static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClipStoreError.emptyName }
        return trimmed
    }

    /// Identifies content: the same text, image or file list hashes the same.
    static func hash(_ candidate: ClipCandidate) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(candidate.kind.rawValue.utf8))
        hasher.update(data: candidate.imageData ?? Data(candidate.text.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
