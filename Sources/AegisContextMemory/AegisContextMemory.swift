import Foundation
import SQLite3
#if canImport(Accelerate)
import Accelerate
#endif
import AegisCore
import AegisEdgeLLM

// MARK: - SQLite WAL Storage Engine (Schema Version 31)

public enum SQLiteError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite Open Failed: \(msg)"
        case .executionFailed(let msg): return "SQLite Execution Failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite Prepare Failed: \(msg)"
        }
    }
}

public struct MemoryChunkRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let tier: String
    public let textBody: String
    public let embedding: [Float]
    public let salience: Double
    public let referenceCount: Int
    public let isConsolidated: Bool
    public let createdAt: Date
}

public struct StandingIntentRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let goalExpression: String
    public let triggerCron: String
    public let status: String
    public let lastEvaluatedAt: Date?
}

public struct ToolJournalEntry: Codable, Sendable, Equatable {
    public let callID: String
    public let turnID: String
    public let sessionID: String
    public let toolName: String
    public let argsJSON: String
    public let status: String // PENDING_EXECUTION, COMPLETED, RECOVERED_FROM_CRASH
    public let outputPath: String?
}

public actor SQLiteWALDatabase {
    public static let schemaVersion: Int32 = 31
    private nonisolated(unsafe) var db: OpaquePointer?
    public nonisolated let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SQLiteError.openFailed(msg)
        }
        self.db = handle
        try Self.configureWALAndMigrate(db: handle!)
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    private static func configureWALAndMigrate(db: OpaquePointer) throws {
        let setupSQL = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        PRAGMA user_version = 31;

        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            channel_source TEXT NOT NULL,
            frozen_memory_hash TEXT NOT NULL,
            kv_cache_path TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS turn_leases (
            session_id TEXT PRIMARY KEY,
            holder_pid TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            acquired_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            coalesced_json TEXT NOT NULL DEFAULT '[]'
        );

        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            thinking TEXT,
            token_count INTEGER NOT NULL,
            promo_score REAL NOT NULL DEFAULT 0.0,
            created_at INTEGER NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            message_id UNINDEXED,
            session_id UNINDEXED,
            content,
            tokenize = 'porter unicode61'
        );

        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(message_id, session_id, content)
            VALUES (new.id, new.session_id, new.content);
        END;

        CREATE TABLE IF NOT EXISTS tool_execution_journal (
            call_id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            args_json TEXT NOT NULL,
            status TEXT NOT NULL,
            output_path TEXT,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS memory_chunks (
            id TEXT PRIMARY KEY,
            tier TEXT NOT NULL,
            text_body TEXT NOT NULL,
            embedding_json TEXT NOT NULL,
            salience REAL NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 1,
            consolidated INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS standing_intents (
            id TEXT PRIMARY KEY,
            goal_expr TEXT NOT NULL,
            trigger_cron TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'ACTIVE',
            last_eval INTEGER
        );

        CREATE TABLE IF NOT EXISTS concept_vocabulary (
            term TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            definition TEXT NOT NULL,
            linked_entities_json TEXT NOT NULL DEFAULT '[]',
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS sender_quarantine (
            sender_key TEXT PRIMARY KEY,
            channel TEXT NOT NULL,
            pairing_code TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'QUARANTINED',
            held_payloads_json TEXT NOT NULL DEFAULT '[]'
        );
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, setupSQL, nil, nil, &errMsg) != SQLITE_OK {
            let str = errMsg.map { String(cString: $0) } ?? "Migration error"
            sqlite3_free(errMsg)
            throw SQLiteError.executionFailed(str)
        }
    }

    public func currentSchemaVersion() throws -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("PRAGMA user_version")
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    public func journalMode() throws -> String {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA journal_mode;", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("PRAGMA journal_mode")
        }
        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr).lowercased()
        }
        return "unknown"
    }

    public func insertMessage(_ message: ChatMessage) throws {
        let sql = """
        INSERT OR REPLACE INTO messages (id, session_id, role, content, thinking, token_count, promo_score, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, message.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, message.sessionID.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, message.role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, message.content, -1, SQLITE_TRANSIENT)
        if let thinking = message.thinking {
            sqlite3_bind_text(stmt, 5, thinking, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_int(stmt, 6, Int32(message.tokenCount))
        sqlite3_bind_double(stmt, 7, message.promotionScore)
        sqlite3_bind_int64(stmt, 8, Int64(message.createdAt.timeIntervalSince1970))

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func searchMessagesFTS5(query: String, limit: Int = 8) throws -> [(messageID: String, content: String, rank: Int)] {
        let sanitized = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " OR ")
        guard !sanitized.isEmpty else { return [] }

        let sql = """
        SELECT message_id, content FROM messages_fts
        WHERE messages_fts MATCH ?
        ORDER BY bm25(messages_fts)
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sanitized, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [(String, String, Int)] = []
        var rankIndex = 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            results.append((id, text, rankIndex))
            rankIndex += 1
        }
        return results
    }

    public func insertMemoryChunk(_ chunk: MemoryChunkRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO memory_chunks (id, tier, text_body, embedding_json, salience, ref_count, consolidated, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        let embData = try JSONEncoder().encode(chunk.embedding)
        let embString = String(data: embData, encoding: .utf8) ?? "[]"
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_text(stmt, 1, chunk.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, chunk.tier, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, chunk.textBody, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, embString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, chunk.salience)
        sqlite3_bind_int(stmt, 6, Int32(chunk.referenceCount))
        sqlite3_bind_int(stmt, 7, chunk.isConsolidated ? 1 : 0)
        sqlite3_bind_int64(stmt, 8, Int64(chunk.createdAt.timeIntervalSince1970))

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.executionFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func fetchAllMemoryChunks(unconsolidatedOnly: Bool = false) throws -> [MemoryChunkRecord] {
        let sql = unconsolidatedOnly
            ? "SELECT id, tier, text_body, embedding_json, salience, ref_count, consolidated, created_at FROM memory_chunks WHERE consolidated = 0;"
            : "SELECT id, tier, text_body, embedding_json, salience, ref_count, consolidated, created_at FROM memory_chunks;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        var chunks: [MemoryChunkRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let tier = String(cString: sqlite3_column_text(stmt, 1))
            let textBody = String(cString: sqlite3_column_text(stmt, 2))
            let embStr = String(cString: sqlite3_column_text(stmt, 3))
            let salience = sqlite3_column_double(stmt, 4)
            let refCount = Int(sqlite3_column_int(stmt, 5))
            let consolidated = sqlite3_column_int(stmt, 6) != 0
            let createdAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 7)))
            let embedding = (try? JSONDecoder().decode([Float].self, from: Data(embStr.utf8))) ?? []
            chunks.append(MemoryChunkRecord(
                id: id,
                tier: tier,
                textBody: textBody,
                embedding: embedding,
                salience: salience,
                referenceCount: refCount,
                isConsolidated: consolidated,
                createdAt: createdAt
            ))
        }
        return chunks
    }

    public func markChunksConsolidated(ids: [String]) throws {
        for id in ids {
            let sql = "UPDATE memory_chunks SET consolidated = 1 WHERE id = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Durable Turn Leases (Cross-Process Mutual Exclusion & Coalescing)

    public func acquireOrCoalesceTurnLease(
        sessionID: SessionID,
        holderPID: String,
        turnID: TurnID,
        ttlSeconds: Int64 = 15,
        inboundMessageJSON: String? = nil
    ) throws -> (acquired: Bool, coalescedPayloads: [String]) {
        let now = Int64(Date().timeIntervalSince1970)
        let selectSQL = "SELECT holder_pid, expires_at, coalesced_json FROM turn_leases WHERE session_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("turn_leases select")
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionID.rawValue, -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            let currentHolder = String(cString: sqlite3_column_text(stmt, 0))
            let expiresAt = sqlite3_column_int64(stmt, 1)
            let coalescedStr = String(cString: sqlite3_column_text(stmt, 2))
            var queue = (try? JSONDecoder().decode([String].self, from: Data(coalescedStr.utf8))) ?? []

            if expiresAt > now && currentHolder != holderPID {
                // Active lease held by another worker -> coalesce inbound message into queue
                if let msg = inboundMessageJSON {
                    queue.append(msg)
                    let updatedStr = String(data: (try? JSONEncoder().encode(queue)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
                    let updateSQL = "UPDATE turn_leases SET coalesced_json = ? WHERE session_id = ?;"
                    var uStmt: OpaquePointer?
                    defer { sqlite3_finalize(uStmt) }
                    if sqlite3_prepare_v2(db, updateSQL, -1, &uStmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(uStmt, 1, updatedStr, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(uStmt, 2, sessionID.rawValue, -1, SQLITE_TRANSIENT)
                        _ = sqlite3_step(uStmt)
                    }
                }
                return (false, queue)
            }
        }

        // Either no lease exists, lease expired, or same owner re-acquiring
        let upsertSQL = """
        INSERT OR REPLACE INTO turn_leases (session_id, holder_pid, turn_id, acquired_at, expires_at, coalesced_json)
        VALUES (?, ?, ?, ?, ?, '[]');
        """
        var iStmt: OpaquePointer?
        defer { sqlite3_finalize(iStmt) }
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &iStmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("turn_leases upsert")
        }
        sqlite3_bind_text(iStmt, 1, sessionID.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(iStmt, 2, holderPID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(iStmt, 3, turnID.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(iStmt, 4, now)
        sqlite3_bind_int64(iStmt, 5, now + ttlSeconds)
        _ = sqlite3_step(iStmt)
        return (true, [])
    }

    public func drainCoalescedMessagesAndReleaseLease(sessionID: SessionID) throws -> [String] {
        var drained: [String] = []
        let selectSQL = "SELECT coalesced_json FROM turn_leases WHERE session_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionID.rawValue, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
                let json = String(cString: cStr)
                drained = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            }
        }
        let delSQL = "DELETE FROM turn_leases WHERE session_id = ?;"
        var dStmt: OpaquePointer?
        defer { sqlite3_finalize(dStmt) }
        if sqlite3_prepare_v2(db, delSQL, -1, &dStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(dStmt, 1, sessionID.rawValue, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(dStmt)
        }
        return drained
    }

    // MARK: - Persist-Before-Execute Tool Execution Journal

    public func recordToolCallPending(
        callID: String,
        turnID: TurnID,
        sessionID: SessionID,
        toolName: String,
        argsJSON: String
    ) throws {
        let sql = """
        INSERT OR REPLACE INTO tool_execution_journal (call_id, turn_id, session_id, tool_name, args_json, status, created_at)
        VALUES (?, ?, ?, ?, ?, 'PENDING_EXECUTION', ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("recordToolCallPending")
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, callID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, turnID.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, sessionID.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, toolName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, argsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.executionFailed("recordToolCallPending step failed")
        }
    }

    public func markToolCallCompleted(callID: String, outputPath: String? = nil) throws {
        let sql = "UPDATE tool_execution_journal SET status = 'COMPLETED', output_path = ? WHERE call_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("markToolCallCompleted")
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let path = outputPath {
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, callID, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    public func recoverOrphanedToolCalls(for sessionID: SessionID) throws -> [ToolJournalEntry] {
        let sql = """
        SELECT call_id, turn_id, session_id, tool_name, args_json, status, output_path
        FROM tool_execution_journal
        WHERE session_id = ? AND status = 'PENDING_EXECUTION';
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed("recoverOrphanedToolCalls")
        }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionID.rawValue, -1, SQLITE_TRANSIENT)

        var orphaned: [ToolJournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let callID = String(cString: sqlite3_column_text(stmt, 0))
            let turnID = String(cString: sqlite3_column_text(stmt, 1))
            let sessID = String(cString: sqlite3_column_text(stmt, 2))
            let toolName = String(cString: sqlite3_column_text(stmt, 3))
            let argsJSON = String(cString: sqlite3_column_text(stmt, 4))
            let status = String(cString: sqlite3_column_text(stmt, 5))
            let outPath = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            orphaned.append(ToolJournalEntry(
                callID: callID,
                turnID: turnID,
                sessionID: sessID,
                toolName: toolName,
                argsJSON: argsJSON,
                status: status,
                outputPath: outPath
            ))
        }

        for entry in orphaned {
            let updateSQL = "UPDATE tool_execution_journal SET status = 'RECOVERED_FROM_CRASH' WHERE call_id = ?;"
            var uStmt: OpaquePointer?
            defer { sqlite3_finalize(uStmt) }
            if sqlite3_prepare_v2(db, updateSQL, -1, &uStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(uStmt, 1, entry.callID, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(uStmt)
            }
        }
        return orphaned
    }

    public func upsertStandingIntent(id: String, goalExpr: String, cron: String) throws {
        let sql = "INSERT OR REPLACE INTO standing_intents (id, goal_expr, trigger_cron, status) VALUES (?, ?, ?, 'ACTIVE');"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, goalExpr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, cron, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    public func fetchActiveStandingIntents() throws -> [StandingIntentRecord] {
        let sql = "SELECT id, goal_expr, trigger_cron, status FROM standing_intents WHERE status = 'ACTIVE';"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var intents: [StandingIntentRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            intents.append(StandingIntentRecord(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                goalExpression: String(cString: sqlite3_column_text(stmt, 1)),
                triggerCron: String(cString: sqlite3_column_text(stmt, 2)),
                status: String(cString: sqlite3_column_text(stmt, 3)),
                lastEvaluatedAt: nil
            ))
        }
        return intents
    }
}

// MARK: - ANE Vector Embeddings & Accelerate Cosine Similarity

public enum ANEEmbeddingService {
    public static let dimension = 64

    /// Generates a deterministic normalized float32 semantic vector (stands in for CoreML bge-small on ANE in unit tests).
    public static func embedText(_ text: String) -> [Float] {
        var vec = [Float](repeating: 0.0, count: dimension)
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return vec }

        for token in tokens {
            let hash = CryptoUtils.sha256Hex(token)
            for (idx, char) in hash.prefix(dimension).enumerated() {
                let val = Float(char.hexDigitValue ?? 0) / 15.0 - 0.5
                vec[idx] += val
            }
        }

        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        if norm > 1e-6 {
            vec = vec.map { $0 / norm }
        }
        return vec
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        #if canImport(Accelerate)
        var dot: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
        #else
        return zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        #endif
    }
}

// MARK: - OpenClaw Short-Term Promotion Scorer

public enum ShortTermPromotionScorer {
    public static let promotionThreshold: Double = 0.65

    public static func computeScore(
        text: String,
        referenceCount: Int = 1,
        ageSeconds: TimeInterval = 0
    ) -> Double {
        let recency = exp(-ageSeconds / 86_400.0)
        let refComponent = log(1.0 + Double(referenceCount))
        let lower = text.lowercased()
        let directiveKeywords = ["remember", "always", "never", "prefer", "my ", "deadline", "important"]
        let hasDirective = directiveKeywords.contains { lower.contains($0) }
        let directiveBoost = hasDirective ? 1.0 : 0.2
        let lengthSalience = min(1.0, Double(text.count) / 160.0)

        return 0.30 * recency + 0.20 * refComponent + 0.35 * directiveBoost + 0.15 * lengthSalience
    }
}

// MARK: - Hermes Two-Tier Declarative Memory Store (Frozen Prefix Invariant)

public actor FrozenMemoryStore {
    private let paths: WorkspacePaths
    private var frozenSessionSnapshots: [SessionID: (memoryMD: String, userMD: String)] = [:]
    private var stagedMemoryAdditions: [String] = []
    private var stagedUserAdditions: [String] = []

    public init(paths: WorkspacePaths) {
        self.paths = paths
    }

    /// Freezes MEMORY.md and USER.md at session boot so mid-session mutations NEVER bust the active Prefix KV-Cache.
    public func freezeSnapshot(for sessionID: SessionID) throws -> (memoryMD: String, userMD: String) {
        if let existing = frozenSessionSnapshots[sessionID] {
            return existing
        }
        let memoryMD = (try? String(contentsOf: paths.memoryFileURL, encoding: .utf8)) ?? ""
        let userMD = (try? String(contentsOf: paths.userFileURL, encoding: .utf8)) ?? ""
        let snapshot = (memoryMD, userMD)
        frozenSessionSnapshots[sessionID] = snapshot
        return snapshot
    }

    /// Appends a declarative fact to disk for FUTURE sessions while keeping the current session's frozen snapshot intact.
    public func stageMemoryUpdate(target: String, entry: String) throws -> String {
        let formatted = "\n- \(entry.trimmingCharacters(in: .whitespacesAndNewlines))"
        if target.lowercased() == "user" {
            stagedUserAdditions.append(entry)
            let currentDisk = (try? String(contentsOf: paths.userFileURL, encoding: .utf8)) ?? ""
            try (currentDisk + formatted).write(to: paths.userFileURL, atomically: true, encoding: .utf8)
            return "Staged update to USER.md (active session prefix cache preserved; takes effect on next session)."
        } else {
            stagedMemoryAdditions.append(entry)
            let currentDisk = (try? String(contentsOf: paths.memoryFileURL, encoding: .utf8)) ?? ""
            try (currentDisk + formatted).write(to: paths.memoryFileURL, atomically: true, encoding: .utf8)
            return "Staged update to MEMORY.md (active session prefix cache preserved; takes effect on next session)."
        }
    }
}

// MARK: - Hermes Procedural Memory: Skill Manager & SkillGuard AST Scanner

public struct SkillDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let category: String
    public let bodyMarkdown: String
    public let filePath: String
}

public enum SkillGuardViolation: Error, LocalizedError, Sendable, Equatable {
    case invalidSkillName(String)
    case missingYAMLFrontmatter
    case dangerousPayloadDetected(pattern: String)
    case pathTraversalDetected

    public var errorDescription: String? {
        switch self {
        case .invalidSkillName(let name): return "Invalid skill name: \(name)"
        case .missingYAMLFrontmatter: return "SKILL.md must begin with valid YAML frontmatter (---)"
        case .dangerousPayloadDetected(let pat): return "SkillGuard blocked dangerous construct: \(pat)"
        case .pathTraversalDetected: return "SkillGuard blocked path traversal sequence (..)"
        }
    }
}

public enum SkillGuardScanner {
    private static let forbiddenPatterns: [String] = [
        "rm -rf",
        "curl http",
        "wget http",
        "eval(",
        "Function(",
        "child_process",
        "/etc/passwd",
        "SecItemCopyMatching",
        "ignore previous instructions",
        "system prompt override"
    ]

    public static func validateSkill(name: String, content: String) throws {
        let nameRegex = try NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-_]{1,48}$")
        let range = NSRange(location: 0, length: name.utf16.count)
        if nameRegex.firstMatch(in: name, range: range) == nil {
            throw SkillGuardViolation.invalidSkillName(name)
        }
        if name.contains("..") || content.contains("../") {
            throw SkillGuardViolation.pathTraversalDetected
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---"),
              trimmed.dropFirst(3).contains("---") else {
            throw SkillGuardViolation.missingYAMLFrontmatter
        }
        let lower = content.lowercased()
        for pattern in forbiddenPatterns {
            if lower.contains(pattern.lowercased()) {
                throw SkillGuardViolation.dangerousPayloadDetected(pattern: pattern)
            }
        }
    }
}

public actor SkillManagerService {
    private let skillsRoot: URL
    private var cache: [String: SkillDescriptor]?

    public init(skillsRoot: URL) {
        self.skillsRoot = skillsRoot
    }

    public func listSkillsCompactIndex() throws -> String {
        let descriptors = try loadAllSkills()
        if descriptors.isEmpty { return "No procedural skills registered." }
        return descriptors
            .sorted { $0.name < $1.name }
            .map { "- \($0.name) [\($0.category)]: \($0.description)" }
            .joined(separator: "\n")
    }

    public func viewSkill(name: String) throws -> String {
        let descriptors = try loadAllSkills()
        guard let match = descriptors.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return "Skill '\(name)' not found."
        }
        return match.bodyMarkdown
    }

    public func manageSkill(
        action: String,
        skillName: String,
        category: String = "custom",
        content: String? = nil
    ) throws -> String {
        switch action.lowercased() {
        case "list":
            return try listSkillsCompactIndex()
        case "view":
            return try viewSkill(name: skillName)
        case "create", "patch":
            guard let body = content else {
                throw SkillGuardViolation.missingYAMLFrontmatter
            }
            try SkillGuardScanner.validateSkill(name: skillName, content: body)
            let dir = skillsRoot
                .appendingPathComponent(category, isDirectory: true)
                .appendingPathComponent(skillName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent("SKILL.md")
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            cache = nil
            return "Skill '\(skillName)' validated by SkillGuardScanner and saved to \(category)/\(skillName)/SKILL.md."
        case "delete":
            let descriptors = try loadAllSkills()
            if let existing = descriptors.first(where: { $0.name == skillName }) {
                try FileManager.default.removeItem(atPath: existing.filePath)
                cache = nil
                return "Deleted skill '\(skillName)'."
            }
            return "Skill '\(skillName)' not found."
        default:
            return "Unsupported skill_manage action: \(action)"
        }
    }

    private func loadAllSkills() throws -> [SkillDescriptor] {
        if let cached = cache { return cached }
        var found: [SkillDescriptor] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: skillsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "SKILL.md" {
            if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
                let name = Self.extractFrontmatterField("name", from: raw)
                    ?? fileURL.deletingLastPathComponent().lastPathComponent
                let desc = Self.extractFrontmatterField("description", from: raw)
                    ?? "Procedural skill"
                let cat = Self.extractFrontmatterField("category", from: raw)
                    ?? fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                found.append(SkillDescriptor(
                    name: name,
                    description: desc,
                    category: cat,
                    bodyMarkdown: raw,
                    filePath: fileURL.path
                ))
            }
        }
        cache = found
        return found
    }

    private static func extractFrontmatterField(_ key: String, from markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - OpenClaw Pluggable Context Engine Contract & Hybrid RRF Implementation

public struct ContextAssembleResult: Sendable {
    public let immutablePrefix: String
    public let prefixHash: String
    public let retrievedMemoryBlock: String
    public let compactedHistory: [ChatMessage]
}

public protocol ContextEngineProtocol: Sendable {
    var engineID: String { get }
    func bootstrap(sessionID: SessionID) async throws -> (memoryMD: String, userMD: String)
    func ingest(message: ChatMessage) async throws
    func assemble(
        sessionID: SessionID,
        query: String,
        history: [ChatMessage],
        systemPrompt: String,
        sortedToolSchemasJSON: String,
        budget: TurnBudgetLimits
    ) async throws -> ContextAssembleResult
    func compact(history: [ChatMessage], targetTokenLimit: Int) async throws -> [ChatMessage]
}

public actor HybridSQLiteContextEngine: ContextEngineProtocol {
    public nonisolated let engineID: String = "aegis-hybrid-sqlite-rrf"
    private let database: SQLiteWALDatabase
    private let frozenMemoryStore: FrozenMemoryStore
    private let skillManager: SkillManagerService

    public init(
        database: SQLiteWALDatabase,
        frozenMemoryStore: FrozenMemoryStore,
        skillManager: SkillManagerService
    ) {
        self.database = database
        self.frozenMemoryStore = frozenMemoryStore
        self.skillManager = skillManager
    }

    public func bootstrap(sessionID: SessionID) async throws -> (memoryMD: String, userMD: String) {
        try await frozenMemoryStore.freezeSnapshot(for: sessionID)
    }

    public func ingest(message: ChatMessage) async throws {
        let score = ShortTermPromotionScorer.computeScore(text: message.content)
        let scoredMessage = ChatMessage(
            id: message.id,
            sessionID: message.sessionID,
            role: message.role,
            content: message.content,
            thinking: message.thinking,
            toolCalls: message.toolCalls,
            toolCallID: message.toolCallID,
            tokenCount: message.tokenCount,
            promotionScore: score,
            createdAt: message.createdAt
        )
        try await database.insertMessage(scoredMessage)

        if score >= ShortTermPromotionScorer.promotionThreshold && message.role == .user {
            let chunk = MemoryChunkRecord(
                id: "mem_\(message.id)",
                tier: "short_term_promoted",
                textBody: message.content,
                embedding: ANEEmbeddingService.embedText(message.content),
                salience: score,
                referenceCount: 1,
                isConsolidated: false,
                createdAt: message.createdAt
            )
            try await database.insertMemoryChunk(chunk)
        }
    }

    public func assemble(
        sessionID: SessionID,
        query: String,
        history: [ChatMessage],
        systemPrompt: String,
        sortedToolSchemasJSON: String,
        budget: TurnBudgetLimits
    ) async throws -> ContextAssembleResult {
        let (frozenMemory, frozenUser) = try await frozenMemoryStore.freezeSnapshot(for: sessionID)
        let skillsIndex = try await skillManager.listSkillsCompactIndex()

        let (immutablePrefix, prefixHash) = PrefixKVCacheManager.buildCanonicalImmutablePrefix(
            systemPrompt: systemPrompt,
            frozenMemoryMD: frozenMemory,
            frozenUserMD: frozenUser,
            sortedToolSchemasJSON: sortedToolSchemasJSON,
            compactSkillsIndex: skillsIndex
        )

        // Hybrid Recall: FTS5 BM25 + Accelerate vDSP Cosine Similarity merged via Reciprocal Rank Fusion (RRF)
        let ftsHits = try await database.searchMessagesFTS5(query: query, limit: 6)
        let allChunks = try await database.fetchAllMemoryChunks()
        let queryVec = ANEEmbeddingService.embedText(query)

        let vecRanked = allChunks
            .map { chunk -> (chunk: MemoryChunkRecord, sim: Float) in
                (chunk, ANEEmbeddingService.cosineSimilarity(queryVec, chunk.embedding))
            }
            .sorted { $0.sim > $1.sim }
            .prefix(6)

        var rrfScores: [String: (text: String, score: Double)] = [:]
        for (idx, hit) in ftsHits.enumerated() {
            let rrf = 1.0 / Double(60 + idx + 1)
            rrfScores[hit.messageID] = (hit.content, (rrfScores[hit.messageID]?.score ?? 0.0) + rrf)
        }
        for (idx, item) in vecRanked.enumerated() {
            let rrf = (1.0 / Double(60 + idx + 1)) + 0.15 * item.chunk.salience
            let key = item.chunk.id
            rrfScores[key] = (item.chunk.textBody, (rrfScores[key]?.score ?? 0.0) + rrf)
        }

        let topMemories = rrfScores.values
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { "- \($0.text)" }
            .joined(separator: "\n")

        let prefixTokens = max(1, immutablePrefix.count / 4)
        let historyTokens = history.reduce(0) { $0 + $1.tokenCount }
        let availableHistoryBudget = max(512, budget.maxContextTokens - budget.reservedOutputTokens - prefixTokens)

        let effectiveHistory: [ChatMessage]
        if historyTokens > availableHistoryBudget {
            effectiveHistory = try await compact(history: history, targetTokenLimit: availableHistoryBudget)
        } else {
            effectiveHistory = history
        }

        return ContextAssembleResult(
            immutablePrefix: immutablePrefix,
            prefixHash: prefixHash,
            retrievedMemoryBlock: topMemories,
            compactedHistory: effectiveHistory
        )
    }

    public func compact(history: [ChatMessage], targetTokenLimit: Int) async throws -> [ChatMessage] {
        guard history.count > 4 else { return history }
        let midpoint = history.count / 2
        let olderSlice = history.prefix(midpoint)
        let recentSlice = Array(history.suffix(from: midpoint))

        let summaryText = "[Compacted Checkpoint Summary of \(olderSlice.count) earlier messages]: " +
            olderSlice.map { "\($0.role.rawValue): \($0.content.prefix(80))" }.joined(separator: " | ")
        let summaryMsg = ChatMessage(
            sessionID: history[0].sessionID,
            role: .system,
            content: summaryText
        )
        return [summaryMsg] + recentSlice
    }
}

// MARK: - OpenClaw Nightly Dreaming Consolidation Engine

public struct DreamingConsolidationReport: Codable, Sendable, Equatable {
    public let consolidatedChunkCount: Int
    public let synthesizedSummaryMarkdown: String
    public let activeStandingIntentsCount: Int
    public let dreamFilePath: String
}

public actor DreamingConsolidator {
    private let database: SQLiteWALDatabase
    private let paths: WorkspacePaths
    private let frozenMemoryStore: FrozenMemoryStore

    public init(database: SQLiteWALDatabase, paths: WorkspacePaths, frozenMemoryStore: FrozenMemoryStore) {
        self.database = database
        self.paths = paths
        self.frozenMemoryStore = frozenMemoryStore
    }

    public func runDreamingConsolidation() async throws -> DreamingConsolidationReport {
        let unconsolidated = try await database.fetchAllMemoryChunks(unconsolidatedOnly: true)
        let activeIntents = try await database.fetchActiveStandingIntents()

        var synthesizedFacts: [String] = []
        for chunk in unconsolidated {
            synthesizedFacts.append("- [Salience \(String(format: "%.2f", chunk.salience))] \(chunk.textBody)")
        }

        if !unconsolidated.isEmpty {
            let summaryFact = "Dreaming Consolidation synthesized \(unconsolidated.count) promoted episodic memories."
            _ = try await frozenMemoryStore.stageMemoryUpdate(target: "user", entry: summaryFact)
            try await database.markChunksConsolidated(ids: unconsolidated.map(\.id))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let dreamFileURL = paths.dreamsDir.appendingPathComponent("\(dateStr)-dream.md")

        let dreamMarkdown = """
        # Nightly Dreaming Consolidation Audit (\(dateStr))
        - Promoted & Consolidated Chunks: \(unconsolidated.count)
        - Active Standing Intents Evaluated: \(activeIntents.count)

        ## Consolidated Episodic Memories
        \(synthesizedFacts.isEmpty ? "- No new unconsolidated chunks." : synthesizedFacts.joined(separator: "\n"))

        ## Active Standing Intents
        \(activeIntents.isEmpty ? "- None active." : activeIntents.map { "- [\($0.triggerCron)] \($0.goalExpression)" }.joined(separator: "\n"))
        """
        try dreamMarkdown.write(to: dreamFileURL, atomically: true, encoding: .utf8)

        return DreamingConsolidationReport(
            consolidatedChunkCount: unconsolidated.count,
            synthesizedSummaryMarkdown: dreamMarkdown,
            activeStandingIntentsCount: activeIntents.count,
            dreamFilePath: dreamFileURL.path
        )
    }
}
