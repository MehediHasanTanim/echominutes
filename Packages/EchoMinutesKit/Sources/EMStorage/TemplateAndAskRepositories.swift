import EMCore
import Foundation
import GRDB

/// User summary templates (EM-170), stored as JSON in the `templates` table (`is_builtin = 0`).
public struct TemplateRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func all() throws -> [UserTemplate] {
        try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT definition_json FROM templates WHERE is_builtin = 0")
                .compactMap { try? JSONDecoder().decode(UserTemplate.self, from: Data($0.utf8)) }
                .sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
        }
    }

    public func save(_ t: UserTemplate) throws {
        let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        try db.writer.write {
            try $0.execute(sql: """
                INSERT INTO templates (id, name, definition_json, is_builtin) VALUES (?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, definition_json = excluded.definition_json
                """, arguments: [t.id, t.name, json])
        }
    }

    public func delete(_ id: String) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM templates WHERE id = ? AND is_builtin = 0", arguments: [id]) }
    }
}

/// "Ask the meeting" chat history (EM-176).
public struct AskRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func messages(_ sessionID: SessionID) throws -> [AskMessage] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ask_messages WHERE session_id = ? ORDER BY created_at, rowid",
                             arguments: [sessionID.description]).map { r in
                AskMessage(id: r["id"], sessionID: sessionID, role: AskMessage.Role(rawValue: r["role"]) ?? .assistant,
                           text: r["text"], createdAt: r["created_at"],
                           provider: (r["provider"] as String?).flatMap(ProviderID.init(rawValue:)), model: r["model"],
                           tokensIn: r["tokens_in"], tokensOut: r["tokens_out"], costUSD: r["cost_usd"])
            }
        }
    }

    public func append(_ m: AskMessage) throws {
        try db.writer.write {
            try $0.execute(sql: """
                INSERT INTO ask_messages (id, session_id, role, text, created_at, provider, model, tokens_in, tokens_out, cost_usd)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [m.id, m.sessionID.description, m.role.rawValue, m.text, m.createdAt, m.provider?.rawValue,
                                 m.model, m.tokensIn, m.tokensOut, m.costUSD])
        }
    }

    public func clear(_ sessionID: SessionID) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM ask_messages WHERE session_id = ?", arguments: [sessionID.description]) }
    }

    public func totalCost(since date: Date) throws -> Double {
        try db.writer.read {
            try Double.fetchOne($0, sql: "SELECT COALESCE(SUM(cost_usd), 0) FROM ask_messages WHERE created_at >= ?", arguments: [date]) ?? 0
        }
    }
}
