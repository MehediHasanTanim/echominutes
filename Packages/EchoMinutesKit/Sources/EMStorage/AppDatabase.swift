import EMCore
import Foundation
import GRDB

/// SQLite database (GRDB) with migrations (Technical Design §11.2). EM-023.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Production database in WAL mode at `paths.databaseURL`.
    public static func onDisk(_ paths: AppPaths) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "EchoMinutes"
        return try AppDatabase(DatabasePool(path: paths.databaseURL.path, configuration: config))
    }

    /// Empty in-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false
        #endif
        m.registerMigration("v1") { db in try db.execute(sql: schemaV1) }
        return m
    }

    static let schemaV1 = """
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      title_is_user_edited INTEGER NOT NULL DEFAULT 0,
      source_app_id TEXT,
      source_bundle_id TEXT,
      started_at DATETIME NOT NULL,
      ended_at DATETIME,
      status TEXT NOT NULL,
      echo_risk INTEGER NOT NULL DEFAULT 0,
      stt_engine TEXT, llm_provider TEXT, llm_model TEXT, template_id TEXT,
      notes_md TEXT,
      tags TEXT NOT NULL DEFAULT '[]',
      created_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    );
    CREATE INDEX idx_sessions_started ON sessions(started_at DESC);
    CREATE INDEX idx_sessions_status ON sessions(status);

    CREATE TABLE audio_tracks (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL, path TEXT NOT NULL, codec TEXT, sample_rate INTEGER, duration_ms INTEGER, size_bytes INTEGER
    );

    CREATE TABLE speakers (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      label TEXT NOT NULL, display_name TEXT, is_me INTEGER NOT NULL DEFAULT 0, color TEXT
    );

    CREATE TABLE transcript_segments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      speaker_id TEXT REFERENCES speakers(id) ON DELETE SET NULL,
      track_kind TEXT NOT NULL,
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      text TEXT NOT NULL, confidence REAL, is_edited INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_segments_session_time ON transcript_segments(session_id, start_ms);

    CREATE TABLE summaries (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      template_id TEXT, provider TEXT, model TEXT,
      json TEXT, markdown TEXT NOT NULL, schema_valid INTEGER NOT NULL,
      tokens_in INTEGER, tokens_out INTEGER, cost_usd REAL,
      is_current INTEGER NOT NULL DEFAULT 1, created_at DATETIME NOT NULL
    );
    CREATE INDEX idx_summaries_session ON summaries(session_id, is_current);

    CREATE TABLE action_items (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      summary_id TEXT REFERENCES summaries(id) ON DELETE SET NULL,
      text TEXT NOT NULL, owner TEXT, due TEXT, timestamp_ms INTEGER,
      is_done INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE bookmarks (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      at_ms INTEGER NOT NULL, note TEXT
    );

    CREATE TABLE templates (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, definition_json TEXT NOT NULL, is_builtin INTEGER NOT NULL
    );

    CREATE TABLE app_rules (
      app_id TEXT PRIMARY KEY,
      mode TEXT NOT NULL DEFAULT 'auto',
      debounce_sec REAL, grace_sec REAL,
      local_only INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE provider_configs (
      provider_id TEXT PRIMARY KEY,
      enabled INTEGER NOT NULL, model TEXT, base_url TEXT, extra_json TEXT
    );

    CREATE TABLE jobs (
      id TEXT PRIMARY KEY,
      session_id TEXT REFERENCES sessions(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      status TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      not_before DATETIME,
      created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL
    );
    CREATE INDEX idx_jobs_status ON jobs(status, not_before);

    CREATE VIRTUAL TABLE search_fts USING fts5(
      session_id UNINDEXED, kind UNINDEXED, ref_id UNINDEXED, start_ms UNINDEXED, body,
      tokenize = 'unicode61 remove_diacritics 2'
    );
    """
}
