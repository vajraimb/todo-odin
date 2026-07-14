package store

import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:time"

// DB is the global database handle, set by init_db and used by all store procs.
DB: Database

// DB_Error is the error type returned by store procs.
// nil = success; non-nil = error message.
DB_Error :: Maybe(string)

// DB_PATH is the filesystem path to the SQLite database file.
// Defaults to ./data.db; override with the DB_PATH environment variable.
DB_PATH: string

// init_db opens (or creates) the SQLite database and runs migrations.
// Must be called once at program start, before any store procs are used.
init_db :: proc() -> DB_Error {
	DB_PATH = os.lookup_env_alloc("DB_PATH", context.allocator) or_else "./data.db"

	db, rc := open(DB_PATH)
	if rc != OK {
		return fmt.tprintf("failed to open database %q: %s (rc=%d)", DB_PATH, err_str(db), rc)
	}

	// Recommended PRAGMAs for write safety and WAL mode (better concurrency).
	exec_ignore_rc(db, "PRAGMA journal_mode=WAL;")
	exec_ignore_rc(db, "PRAGMA synchronous=NORMAL;")
	exec_ignore_rc(db, "PRAGMA foreign_keys=ON;")
	exec_ignore_rc(db, "PRAGMA busy_timeout=5000;")

	if err := migrate(db); err != nil {
		return err
	}

	DB = db
	log.infof("database ready: %s (sqlite %s)", DB_PATH, libversion_string())
	return nil
}

libversion_string :: proc() -> string {
	cs := libversion()
	if cs == nil do return "?"
	return string(cs)
}

exec_ignore_rc :: proc(db: Database, sql: string) {
	rc := exec_sql(db, sql)
	if rc != OK {
		log.warnf("pragma/exec failed (rc=%d): %s — %s", rc, sql, err_str(db))
	}
}

// === Migrations ===
//
// Simple migration system: a `schema_version` meta table tracks the current version.
// Each migration is a (version, sql) pair; we apply them in order.

Migration :: struct {
	version: int,
	sql:     string,
}

MIGRATIONS := []Migration{
	{1, `
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    display_name TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    last_activity INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS todos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    title TEXT NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_todos_user ON todos(user_id);
CREATE INDEX IF NOT EXISTS idx_todos_user_completed ON todos(user_id, completed);

CREATE TABLE IF NOT EXISTS reminders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    todo_id INTEGER NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id),
    remind_at INTEGER NOT NULL,
    timezone TEXT,
    fired INTEGER NOT NULL DEFAULT 0,
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(remind_at) WHERE fired = 0;
CREATE INDEX IF NOT EXISTS idx_reminders_user ON reminders(user_id);

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);
`},
	{2, `
ALTER TABLE users ADD COLUMN tg_chat_id INTEGER;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_tg_chat ON users(tg_chat_id) WHERE tg_chat_id IS NOT NULL;
`},
	{3, `
ALTER TABLE users ADD COLUMN webhook_url TEXT;
`},
	{4, `
CREATE TABLE IF NOT EXISTS api_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL,
    name TEXT,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_tokens_hash ON api_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_tokens_user ON api_tokens(user_id);
`},
	{5, `
CREATE TABLE IF NOT EXISTS passkey_credentials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    credential_id TEXT NOT NULL UNIQUE,
    public_key BLOB NOT NULL,
    counter INTEGER NOT NULL DEFAULT 0,
    transports TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_passkey_user ON passkey_credentials(user_id);
`},
	{6, `
CREATE TABLE IF NOT EXISTS login_tokens (
    token TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    expires INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);
`},
	{7, `
CREATE TABLE IF NOT EXISTS reminder_recipients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    reminder_id INTEGER NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    webhook_url TEXT NOT NULL,
    label TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_recipients_reminder ON reminder_recipients(reminder_id);
`},
}

migrate :: proc(db: Database) -> DB_Error {
	// Ensure schema_version table exists.
	exec_ignore_rc(db, `
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);
`)

	current := get_schema_version(db)

	for m in MIGRATIONS {
		if m.version <= current do continue
		log.infof("applying migration v{}", m.version)
		rc := exec_sql(db, m.sql)
		if rc != OK {
			return fmt.tprintf("migration v%d failed (rc=%d): %s", m.version, rc, err_str(db))
		}
		set_schema_version(db, m.version)
	}

	return nil
}

get_schema_version :: proc(db: Database) -> int {
	stmt, rc := prepare(db, "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1;")
	if rc != OK do return 0
	defer finalize_safe(stmt)

	if step_row(stmt) {
		return int(column_int64(stmt, 0))
	}
	return 0
}

set_schema_version :: proc(db: Database, version: int) {
	stmt, rc := prepare(db, "INSERT INTO schema_version (version) VALUES (?);")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, i64(version))
	_ = step(stmt)
}

// now_unix returns the current time as a Unix timestamp (seconds).
now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}
