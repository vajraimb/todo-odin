package store

import "core:c"
import "core:strings"

// Minimal hand-written Odin binding for the subset of SQLite's C API that we need.
// The static library is compiled from the sqlite3 amalgamation in vendor/sqlite/.
//
// Link the library when building:
//   odin build . -out:app -extra-linker-flags:"vendor/sqlite/libsqlite3.a"

foreign import lib "../vendor/sqlite/libsqlite3.a"

// Opaque handle types. SQLite treats these as opaque pointers from the user's
// perspective, so we model them as distinct rawptrs.
Database :: distinct rawptr
Stmt :: distinct rawptr

// Result codes.
OK :: 0
ROW :: 100
DONE :: 101
BUSY :: 5
LOCKED :: 6
CONSTRAINT :: 19

// Open flags.
OPEN_READONLY :: 0x00000001
OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004
OPEN_FULLMUTEX :: 0x00010000
OPEN_URI :: 0x00000040

// Column types.
TYPE_INTEGER :: 1
TYPE_FLOAT :: 2
TYPE_TEXT :: 3
TYPE_BLOB :: 4
TYPE_NULL :: 5

// Destructor constants for bind_text/bind_blob.
// SQLITE_TRANSIENT = -1 (SQLite copies the data).
// SQLITE_STATIC = 0 (SQLite does not copy).
DESTRUCTOR_TRANSIENT :: rawptr(~uintptr(0))
DESTRUCTOR_STATIC :: rawptr(uintptr(0))

// to_cstring copies an Odin string into a null-terminated cstring using the
// temp allocator. Use this when passing strings to C functions.
to_cstring :: proc(s: string) -> cstring {
	if len(s) == 0 do return cstring("")
	cs := strings.clone_to_cstring(s, context.temp_allocator) or_else cstring("")
	return cs
}

// === Core functions ===

foreign lib {
	@(link_name="sqlite3_open_v2")
	open_v2 :: proc(filename: cstring, db: ^Database, flags: c.int, vfs: cstring) -> c.int ---
	@(link_name="sqlite3_close_v2")
	close_v2 :: proc(db: Database) -> c.int ---
	@(link_name="sqlite3_prepare_v2")
	prepare_v2 :: proc(db: Database, sql: cstring, nByte: c.int, stmt: ^Stmt, tail: ^cstring) -> c.int ---
	@(link_name="sqlite3_step")
	step :: proc(stmt: Stmt) -> c.int ---
	@(link_name="sqlite3_reset")
	reset :: proc(stmt: Stmt) -> c.int ---
	@(link_name="sqlite3_finalize")
	finalize :: proc(stmt: Stmt) -> c.int ---

	@(link_name="sqlite3_exec")
	exec :: proc(db: Database, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---

	@(link_name="sqlite3_errmsg")
	errmsg :: proc(db: Database) -> cstring ---
	@(link_name="sqlite3_libversion")
	libversion :: proc() -> cstring ---

	@(link_name="sqlite3_last_insert_rowid")
	last_insert_rowid :: proc(db: Database) -> i64 ---
	@(link_name="sqlite3_changes")
	changes :: proc(db: Database) -> c.int ---

	// Bind functions. Index is 1-based.
	@(link_name="sqlite3_bind_int")
	bind_int :: proc(stmt: Stmt, idx: c.int, value: c.int) -> c.int ---
	@(link_name="sqlite3_bind_int64")
	bind_int64 :: proc(stmt: Stmt, idx: c.int, value: i64) -> c.int ---
	@(link_name="sqlite3_bind_text")
	bind_text :: proc(stmt: Stmt, idx: c.int, text: cstring, nByte: c.int, destructor: rawptr) -> c.int ---
	@(link_name="sqlite3_bind_blob")
	bind_blob :: proc(stmt: Stmt, idx: c.int, blob: rawptr, nByte: c.int, destructor: rawptr) -> c.int ---
	@(link_name="sqlite3_bind_null")
	bind_null :: proc(stmt: Stmt, idx: c.int) -> c.int ---

	// Column functions. Index is 0-based.
	@(link_name="sqlite3_column_count")
	column_count :: proc(stmt: Stmt) -> c.int ---
	@(link_name="sqlite3_column_type")
	column_type :: proc(stmt: Stmt, idx: c.int) -> c.int ---
	@(link_name="sqlite3_column_int")
	column_int :: proc(stmt: Stmt, idx: c.int) -> c.int ---
	@(link_name="sqlite3_column_int64")
	column_int64 :: proc(stmt: Stmt, idx: c.int) -> i64 ---
	@(link_name="sqlite3_column_text")
	column_text :: proc(stmt: Stmt, idx: c.int) -> cstring ---
	@(link_name="sqlite3_column_blob")
	column_blob :: proc(stmt: Stmt, idx: c.int) -> rawptr ---
	@(link_name="sqlite3_column_bytes")
	column_bytes :: proc(stmt: Stmt, idx: c.int) -> c.int ---
	@(link_name="sqlite3_column_name")
	column_name :: proc(stmt: Stmt, idx: c.int) -> cstring ---
}

// Convenience wrappers

// open opens (or creates) a SQLite database file.
// Uses READWRITE | CREATE | FULLMUTEX for thread-safe read/write access.
open :: proc(path: string) -> (Database, c.int) {
	db: Database
	c_path := to_cstring(path)
	rc := open_v2(c_path, &db, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX, nil)
	return db, rc
}

// close closes the database connection.
close :: proc(db: Database) -> c.int {
	return close_v2(db)
}

// prepare compiles a SQL statement. Returns the statement and the result code.
prepare :: proc(db: Database, sql: string) -> (Stmt, c.int) {
	stmt: Stmt
	c_sql := to_cstring(sql)
	rc := prepare_v2(db, c_sql, c.int(len(sql)), &stmt, nil)
	return stmt, rc
}

// exec_sql is a convenience wrapper around exec that takes an Odin string.
exec_sql :: proc(db: Database, sql: string) -> c.int {
	return exec(db, to_cstring(sql), nil, nil, nil)
}

// step_row returns true if step returned ROW (more data available).
step_row :: proc(stmt: Stmt) -> bool {
	return step(stmt) == ROW
}

// step_done returns true if step returned DONE (statement finished).
step_done :: proc(stmt: Stmt) -> bool {
	rc := step(stmt)
	return rc == DONE
}

// column_string reads a text column as an Odin string.
// IMPORTANT: SQLite's text buffer is invalidated on the next step/reset/finalize,
// so we clone the data to the temp allocator to make it safe to retain.
column_string :: proc(stmt: Stmt, idx: int) -> string {
	cs := column_text(stmt, c.int(idx))
	if cs == nil do return ""
	return strings.clone(string(cs), context.temp_allocator)
}

// bind_string binds an Odin string to a parameter. SQLite copies the data (TRANSIENT).
bind_string :: proc(stmt: Stmt, idx: int, value: string) -> c.int {
	return bind_text(stmt, c.int(idx), to_cstring(value), c.int(len(value)), DESTRUCTOR_TRANSIENT)
}

// finalize_safe finalizes a statement, ignoring the return code.
finalize_safe :: proc(stmt: Stmt) {
	_ = finalize(stmt)
}

// err_str returns the error message for the given database connection.
err_str :: proc(db: Database) -> string {
	cs := errmsg(db)
	if cs == nil do return ""
	return string(cs)
}
