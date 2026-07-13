package store

import "core:c"
import "core:fmt"
import "core:log"

// === Users ===

// create_user creates a new anonymous user (no auth yet; P5 will add passkeys/tokens).
// Returns the new user's id.
create_user :: proc(db: Database, display_name: string = "") -> (i64, DB_Error) {
	stmt, rc := prepare(db, "INSERT INTO users (created_at, display_name) VALUES (?, ?);")
	if rc != OK {
		return 0, fmt.tprintf("create_user prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, now_unix())
	if len(display_name) > 0 {
		_ = bind_string(stmt, 2, display_name)
	} else {
		_ = bind_null(stmt, 2)
	}

	rc = step(stmt)
	if rc != DONE {
		return 0, fmt.tprintf("create_user step failed (rc=%d): %s", rc, err_str(db))
	}

	return last_insert_rowid(db), nil
}

// === Sessions ===

// create_session creates a new session row tied to a user.
// `session_id` is the cookie value (caller generates a random base32 string).
create_session :: proc(db: Database, session_id: string, user_id: i64) -> DB_Error {
	stmt, rc := prepare(db, `
INSERT INTO sessions (id, user_id, last_activity, created_at)
VALUES (?, ?, ?, ?);
`)
	if rc != OK {
		return fmt.tprintf("create_session prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	now := now_unix()
	_ = bind_string(stmt, 1, session_id)
	_ = bind_int64(stmt, 2, user_id)
	_ = bind_int64(stmt, 3, now)
	_ = bind_int64(stmt, 4, now)

	rc = step(stmt)
	if rc != DONE {
		return fmt.tprintf("create_session step failed (rc=%d): %s", rc, err_str(db))
	}
	return nil
}

// Session_Result is what session_lookup returns on success.
Session_Result :: struct {
	session_id:    string,
	user_id:       i64,
	last_activity: i64,
}

// session_lookup finds a session by its cookie id. Returns (result, true) if found.
// Also updates last_activity on hit.
session_lookup :: proc(db: Database, session_id: string) -> (Session_Result, bool) {
	stmt, rc := prepare(db, "SELECT user_id, last_activity FROM sessions WHERE id = ?;")
	if rc != OK do return {}, false
	defer finalize_safe(stmt)

	_ = bind_string(stmt, 1, session_id)
	if !step_row(stmt) do return {}, false

	user_id := column_int64(stmt, 0)
	last_activity := column_int64(stmt, 1)

	// Update last_activity (fire-and-forget; failure is non-fatal).
	_ = touch_session(db, session_id)

	return Session_Result{
		session_id = session_id,
		user_id = user_id,
		last_activity = last_activity,
	}, true
}

touch_session :: proc(db: Database, session_id: string) -> i32 {
	stmt, rc := prepare(db, "UPDATE sessions SET last_activity = ? WHERE id = ?;")
	if rc != OK do return rc
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, now_unix())
	_ = bind_string(stmt, 2, session_id)
	return step(stmt)
}

// link_session_to_user updates a session to point to a different user_id.
// Used when an anonymous session is "upgraded" via passkey login.
link_session_to_user :: proc(db: Database, session_id: string, user_id: i64) -> i32 {
	stmt, rc := prepare(db, "UPDATE sessions SET user_id = ? WHERE id = ?;")
	if rc != OK do return rc
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, user_id)
	_ = bind_string(stmt, 2, session_id)
	return step(stmt)
}

// === Todos ===

// Todo_Row is the database representation of a todo.
Todo_Row :: struct {
	id:        i64,
	user_id:   i64,
	title:     string,
	completed: bool,
	created_at: i64,
	updated_at: i64,
}

// create_todo inserts a new todo for the given user. Returns the new todo's id.
create_todo :: proc(db: Database, user_id: i64, title: string) -> (i64, DB_Error) {
	stmt, rc := prepare(db, `
INSERT INTO todos (user_id, title, completed, created_at, updated_at)
VALUES (?, ?, 0, ?, ?);
`)
	if rc != OK {
		return 0, fmt.tprintf("create_todo prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	now := now_unix()
	_ = bind_int64(stmt, 1, user_id)
	_ = bind_string(stmt, 2, title)
	_ = bind_int64(stmt, 3, now)
	_ = bind_int64(stmt, 4, now)

	rc = step(stmt)
	if rc != DONE {
		return 0, fmt.tprintf("create_todo step failed (rc=%d): %s", rc, err_str(db))
	}

	return last_insert_rowid(db), nil
}

// list_todos returns all todos for a user, optionally filtered by completion status.
// filter: .All, .Active (completed=0), .Completed (completed=1)
// Returns a temp-allocated slice; caller should not retain across free_all.
Todo_Filter :: enum { All, Active, Completed }

list_todos :: proc(db: Database, user_id: i64, filter: Todo_Filter) -> ([]Todo_Row, DB_Error) {
	sql: string
	switch filter {
	case .All:       sql = "SELECT id, user_id, title, completed, created_at, updated_at FROM todos WHERE user_id = ? ORDER BY id DESC;"
	case .Active:    sql = "SELECT id, user_id, title, completed, created_at, updated_at FROM todos WHERE user_id = ? AND completed = 0 ORDER BY id DESC;"
	case .Completed: sql = "SELECT id, user_id, title, completed, created_at, updated_at FROM todos WHERE user_id = ? AND completed = 1 ORDER BY id DESC;"
	}

	stmt, rc := prepare(db, sql)
	if rc != OK {
		return nil, fmt.tprintf("list_todos prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)

	out := make([dynamic]Todo_Row, 0, 16, context.temp_allocator)
	for step_row(stmt) {
		row := Todo_Row{
			id = column_int64(stmt, 0),
			user_id = column_int64(stmt, 1),
			title = column_string(stmt, 2),
			completed = column_int(stmt, 3) != 0,
			created_at = column_int64(stmt, 4),
			updated_at = column_int64(stmt, 5),
		}
		append(&out, row)
	}

	return out[:], nil
}

// get_todo fetches a single todo by id, scoped to a user (security: prevents
// users from reading other users' todos).
get_todo :: proc(db: Database, user_id: i64, todo_id: i64) -> (Todo_Row, bool) {
	stmt, rc := prepare(db, "SELECT id, user_id, title, completed, created_at, updated_at FROM todos WHERE id = ? AND user_id = ?;")
	if rc != OK do return {}, false
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, todo_id)
	_ = bind_int64(stmt, 2, user_id)
	if !step_row(stmt) do return {}, false

	return Todo_Row{
		id = column_int64(stmt, 0),
		user_id = column_int64(stmt, 1),
		title = column_string(stmt, 2),
		completed = column_int(stmt, 3) != 0,
		created_at = column_int64(stmt, 4),
		updated_at = column_int64(stmt, 5),
	}, true
}

// update_todo updates a todo's title and/or completed status.
// Pass empty title to leave it unchanged.
update_todo :: proc(db: Database, user_id: i64, todo_id: i64, title: string, has_title: bool, completed: bool) -> DB_Error {
	// Fetch current state to know if we're toggling completion (for count sync).
	row, ok := get_todo(db, user_id, todo_id)
	if !ok {
		return fmt.tprintf("todo %d not found for user %d", todo_id, user_id)
	}

	was_completed := row.completed

	sql: string
	if has_title {
		sql = "UPDATE todos SET title = ?, completed = ?, updated_at = ? WHERE id = ? AND user_id = ?;"
	} else {
		sql = "UPDATE todos SET completed = ?, updated_at = ? WHERE id = ? AND user_id = ?;"
	}

	stmt, rc := prepare(db, sql)
	if rc != OK {
		return fmt.tprintf("update_todo prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	idx := 1
	if has_title {
		_ = bind_string(stmt, idx, title)
		idx += 1
	}
	_ = bind_int(stmt, c.int(idx), completed ? 1 : 0)
	idx += 1
	_ = bind_int64(stmt, c.int(idx), now_unix())
	idx += 1
	_ = bind_int64(stmt, c.int(idx), todo_id)
	idx += 1
	_ = bind_int64(stmt, c.int(idx), user_id)

	rc = step(stmt)
	if rc != DONE {
		return fmt.tprintf("update_todo step failed (rc=%d): %s", rc, err_str(db))
	}

	return nil
}

// delete_todo deletes a todo (and cascades to reminders via FK ON DELETE CASCADE).
// Returns true if a row was actually deleted.
delete_todo :: proc(db: Database, user_id: i64, todo_id: i64) -> bool {
	stmt, rc := prepare(db, "DELETE FROM todos WHERE id = ? AND user_id = ?;")
	if rc != OK do return false
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, todo_id)
	_ = bind_int64(stmt, 2, user_id)
	rc = step(stmt)
	if rc != DONE do return false

	return changes(db) > 0
}

// delete_completed_todos removes all completed todos for a user.
// Returns the number deleted.
delete_completed_todos :: proc(db: Database, user_id: i64) -> int {
	stmt, rc := prepare(db, "DELETE FROM todos WHERE user_id = ? AND completed = 1;")
	if rc != OK do return 0
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)
	rc = step(stmt)
	if rc != DONE do return 0

	return int(changes(db))
}

// set_all_completed sets all todos for a user to the given completed state.
// Returns the number of rows changed.
set_all_completed :: proc(db: Database, user_id: i64, completed: bool) -> int {
	stmt, rc := prepare(db, "UPDATE todos SET completed = ?, updated_at = ? WHERE user_id = ?;")
	if rc != OK do return 0
	defer finalize_safe(stmt)

	_ = bind_int(stmt, 1, completed ? 1 : 0)
	_ = bind_int64(stmt, 2, now_unix())
	_ = bind_int64(stmt, 3, user_id)
	rc = step(stmt)
	if rc != DONE do return 0

	return int(changes(db))
}

// all_todos_completed returns true if the user has at least one todo and all are completed.
all_todos_completed :: proc(db: Database, user_id: i64) -> bool {
	stmt, rc := prepare(db, "SELECT COUNT(*) FROM todos WHERE user_id = ? AND completed = 0;")
	if rc != OK do return false
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)
	if !step_row(stmt) do return false
	active := column_int64(stmt, 0)
	if active > 0 do return false

	// Also check there's at least one todo.
	stmt2, rc2 := prepare(db, "SELECT COUNT(*) FROM todos WHERE user_id = ?;")
	if rc2 != OK do return false
	defer finalize_safe(stmt2)
	_ = bind_int64(stmt2, 1, user_id)
	if !step_row(stmt2) do return false
	total := column_int64(stmt2, 0)
	return total > 0
}

// todo_counts returns (total, active, completed) for a user.
todo_counts :: proc(db: Database, user_id: i64) -> (total: int, active: int, completed: int) {
	stmt, rc := prepare(db, "SELECT COUNT(*), SUM(CASE WHEN completed = 0 THEN 1 ELSE 0 END) FROM todos WHERE user_id = ?;")
	if rc != OK do return 0, 0, 0
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)
	if !step_row(stmt) do return 0, 0, 0

	total = int(column_int64(stmt, 0))
	// SUM returns NULL if no rows; column_type will be TYPE_NULL.
	if column_type(stmt, 1) != TYPE_NULL {
		active = int(column_int64(stmt, 1))
	}
	completed = total - active
	return
}

// === Telegram chat <-> user mapping ===

// find_user_by_tg_chat looks up a user by their Telegram chat_id.
// Returns (user_id, true) if found.
find_user_by_tg_chat :: proc(db: Database, chat_id: i64) -> (user_id: i64, found: bool) {
	stmt, rc := prepare(db, "SELECT id FROM users WHERE tg_chat_id = ?;")
	if rc != OK do return 0, false
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, chat_id)
	if !step_row(stmt) do return 0, false
	return column_int64(stmt, 0), true
}

// create_user_with_tg_chat creates a new user with a linked Telegram chat_id.
// Returns the new user's id.
create_user_with_tg_chat :: proc(db: Database, chat_id: i64, display_name: string) -> (i64, DB_Error) {
	stmt, rc := prepare(db, "INSERT INTO users (created_at, display_name, tg_chat_id) VALUES (?, ?, ?);")
	if rc != OK {
		return 0, fmt.tprintf("create_user_with_tg_chat prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, now_unix())
	if len(display_name) > 0 {
		_ = bind_string(stmt, 2, display_name)
	} else {
		_ = bind_null(stmt, 2)
	}
	_ = bind_int64(stmt, 3, chat_id)

	rc = step(stmt)
	if rc != DONE {
		return 0, fmt.tprintf("create_user_with_tg_chat step failed (rc=%d): %s", rc, err_str(db))
	}
	return last_insert_rowid(db), nil
}

// find_or_create_tg_user finds a user by chat_id, or creates one if not found.
find_or_create_tg_user :: proc(db: Database, chat_id: i64, display_name: string) -> (i64, DB_Error) {
	if uid, found := find_user_by_tg_chat(db, chat_id); found {
		return uid, nil
	}
	return create_user_with_tg_chat(db, chat_id, display_name)
}

// === Reminders ===

// create_reminder inserts a new reminder for a todo.
create_reminder :: proc(db: Database, todo_id: i64, user_id: i64, remind_at: i64, timezone: string = "") -> (i64, DB_Error) {
	stmt, rc := prepare(db, `
INSERT INTO reminders (todo_id, user_id, remind_at, timezone, fired, retry_count, created_at)
VALUES (?, ?, ?, ?, 0, 0, ?);
`)
	if rc != OK {
		return 0, fmt.tprintf("create_reminder prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, todo_id)
	_ = bind_int64(stmt, 2, user_id)
	_ = bind_int64(stmt, 3, remind_at)
	if len(timezone) > 0 {
		_ = bind_string(stmt, 4, timezone)
	} else {
		_ = bind_null(stmt, 4)
	}
	_ = bind_int64(stmt, 5, now_unix())

	rc = step(stmt)
	if rc != DONE {
		return 0, fmt.tprintf("create_reminder step failed (rc=%d): %s", rc, err_str(db))
	}
	return last_insert_rowid(db), nil
}

// parse_iso_to_unix converts an ISO 8601 timestamp (e.g. "2024-01-15T15:00:00")
// to a Unix timestamp. This is a simple parser that does NOT handle all ISO variants.
// Returns (timestamp, true) on success, (0, false) on parse failure.
parse_iso_to_unix :: proc(iso: string) -> (i64, bool) {
	if len(iso) < 19 do return 0, false
	// Expected format: YYYY-MM-DDTHH:MM:SS
	// Parse manually to avoid dependencies.
	year, ok1 := _parse_int(iso[0:4])
	month, ok2 := _parse_int(iso[5:7])
	day, ok3 := _parse_int(iso[8:10])
	hour, ok4 := _parse_int(iso[11:13])
	minute, ok5 := _parse_int(iso[14:16])
	second, ok6 := _parse_int(iso[17:19])
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 do return 0, false

	// Convert to Unix timestamp using the civil date algorithm.
	// (Howard Hinnant's algorithm, works for any date in the Gregorian calendar.)
	adjust: i64 = 0
	if month <= 2 { adjust = 1 }
	y := i64(year) - adjust

	era_val: i64
	if y >= 0 { era_val = y / 400 } else { era_val = (y - 399) / 400 }
	yoe := y - era_val * 400

	mo := i64(month)
	d := i64(day)
	mo_adj: i64
	if mo > 2 { mo_adj = mo - 3 } else { mo_adj = mo + 9 }
	doy := (153 * mo_adj + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := era_val * 146097 + doe - 719468

	return days * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second), true
}

_parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 do return 0, false
	n: int = 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' do return 0, false
		n = n*10 + int(c - '0')
	}
	return n, true
}
