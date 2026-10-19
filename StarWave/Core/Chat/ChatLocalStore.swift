import Foundation
import CryptoKit
import SQLite3

/// One encrypted record store per immutable account + relay. All page effects
/// and its cursor commit in ONE SQL transaction, before network acknowledgement.
actor ChatLocalStore {
    private var db: OpaquePointer?
    private let encryptionKey: SymmetricKey
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(namespace: String, key: Data, directory: URL? = nil) throws {
        guard key.count == 32 else { throw ChatFailure.storage }
        encryptionKey = SymmetricKey(data: key)
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chat", isDirectory: true)
        let folder = root.appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var exclude = URLResourceValues(); exclude.isExcludedFromBackup = true
        var protectedFolder = folder; try protectedFolder.setResourceValues(exclude)
        guard sqlite3_open_v2(folder.appendingPathComponent("history.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ChatFailure.storage }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL,id TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(kind,id));", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw ChatFailure.storage
        }
    }
    deinit { sqlite3_close(db) }

    private func seal<T: Encodable>(_ value: T, kind: String, id: String) throws -> Data {
        let sealed = try AES.GCM.seal(JSONEncoder().encode(value), using: encryptionKey, authenticating: Data((kind + ":" + id).utf8))
        guard let bytes = sealed.combined else { throw ChatFailure.storage }; return bytes
    }
    private func open<T: Decodable>(_ type: T.Type, bytes: Data, kind: String, id: String) throws -> T {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: encryptionKey, authenticating: Data((kind + ":" + id).utf8))
        return try JSONDecoder().decode(type, from: plain)
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw ChatFailure.storage }; return stmt
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ChatFailure.storage } }
    private func bind(_ text: String, at index: Int32, to stmt: OpaquePointer) throws {
        guard sqlite3_bind_text(stmt, index, text, -1, transient) == SQLITE_OK else { throw ChatFailure.storage }
    }
    func put<T: Encodable>(_ value: T, kind: String, id: String) throws {
        let bytes = try seal(value, kind: kind, id: id)
        let stmt = try statement("INSERT INTO records(kind,id,value) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET value=excluded.value"); defer { sqlite3_finalize(stmt) }
        try bind(kind, at: 1, to: stmt); try bind(id, at: 2, to: stmt)
        let code = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(bytes.count), transient) }
        guard code == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw ChatFailure.storage }
    }
    func get<T: Decodable>(_ type: T.Type, kind: String, id: String) throws -> T? {
        let stmt = try statement("SELECT value FROM records WHERE kind=? AND id=?"); defer { sqlite3_finalize(stmt) }
        try bind(kind, at: 1, to: stmt); try bind(id, at: 2, to: stmt)
        let code = sqlite3_step(stmt); if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw ChatFailure.storage }
        return try open(type, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))), kind: kind, id: id)
    }
    func all<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        let stmt = try statement("SELECT id,value FROM records WHERE kind=? ORDER BY id"); defer { sqlite3_finalize(stmt) }; try bind(kind, at: 1, to: stmt)
        var result: [T] = []
        while true {
            let code = sqlite3_step(stmt); if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let rawID = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 1) else { throw ChatFailure.storage }
            result.append(try open(type, bytes: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1))), kind: kind, id: String(cString: rawID)))
        }
        return result
    }
    func remove(kind: String, id: String) throws {
        let stmt = try statement("DELETE FROM records WHERE kind=? AND id=?"); defer { sqlite3_finalize(stmt) }
        try bind(kind, at: 1, to: stmt); try bind(id, at: 2, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ChatFailure.storage }
    }
    func commit(events: [JSONValue], messages: [ChatMessage], cursor: String?) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for event in events { try put(event, kind: "event", id: try event.chatSequence("event_seq")) }
            for message in messages {
                try put(message, kind: "message", id: message.id)
                if message.status != "pending", let pending = try get(ChatPendingSend.self, kind: "pending", id: message.clientID), pending.message.sender == message.sender, pending.peerSubject == message.peerSubject {
                    try remove(kind: "pending", id: message.clientID); try remove(kind: "message", id: "pending:" + message.clientID)
                }
            }
            if let cursor { try put(cursor, kind: "state", id: "cursor") }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func savePending(_ pending: ChatPendingSend) throws {
        try execute("BEGIN IMMEDIATE")
        do { try put(pending, kind: "pending", id: pending.id); try put(pending.message, kind: "message", id: pending.message.id); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func clearLocalHistory() throws {
        // Keep cursor, encryption keys and trust pins. This is NOT a key reset
        // and must not replay already acknowledged history on the next launch.
        try execute("DELETE FROM records WHERE kind IN ('message','event','pending','draft')")
    }
    func mergeRestored(_ messages: [ChatMessage], filters: [JSONValue]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for message in messages where ChatHistoryFilter.allows(message, filters: filters) {
                if try get(ChatMessage.self, kind: "message", id: message.id) == nil { try put(message, kind: "message", id: message.id) }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func applyFilters(_ filters: [JSONValue]) throws {
        let messages = try all(ChatMessage.self, kind: "message")
        try execute("BEGIN IMMEDIATE")
        do {
            for var message in messages where !ChatHistoryFilter.allows(message, filters: filters) && message.status != "pending" {
                message.text = nil; message.raw = nil; message.status = "hidden"
                try put(message, kind: "message", id: message.id)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}

enum ChatHistoryFilter {
    static func allows(_ message: ChatMessage, filters: [JSONValue]) -> Bool {
        guard message.status != "hidden", message.status != "recalled", message.status != "pending", Int64(message.sequence) != nil else { return false }
        for f in filters {
            if ["hidden", "recall"].contains(f["type"]?.stringValue ?? ""), f["target"]?.stringValue == message.id { return false }
            if f["type"]?.stringValue == "clear", f["target"]?.stringValue == message.conversationID,
               let through = Int64(f["through_seq"]?.stringValue ?? ""), let seq = Int64(message.sequence), seq <= through { return false }
        }
        return true
    }
}
