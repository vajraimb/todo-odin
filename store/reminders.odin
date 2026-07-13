package store

import "core:fmt"

// Due_Reminder is a reminder that needs to be fired.
Due_Reminder :: struct {
	reminder_id: i64,
	todo_id:     i64,
	user_id:     i64,
	title:       string,    // from joined todos table
	remind_at:   i64,       // unix timestamp
	tg_chat_id:  i64,       // from joined users table (0 if not linked)
	webhook_url: string,    // from joined users table ("" if not set)
}

// list_due_reminders returns all unfired reminders whose remind_at <= now.
// Joins with todos (for title) and users (for tg_chat_id, webhook_url).
list_due_reminders :: proc(db: Database, now: i64) -> (rows: []Due_Reminder, err: DB_Error) {
	stmt, rc := prepare(db, `
SELECT r.id, r.todo_id, r.user_id, t.title, r.remind_at,
       COALESCE(u.tg_chat_id, 0), COALESCE(u.webhook_url, '')
FROM reminders r
JOIN todos t ON r.todo_id = t.id
JOIN users u ON r.user_id = u.id
WHERE r.fired = 0 AND r.remind_at <= ?;
`)
	if rc != OK {
		return nil, fmt.tprintf("list_due_reminders prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, now)

	out := make([dynamic]Due_Reminder, 0, 16, context.temp_allocator)
	for step_row(stmt) {
		row := Due_Reminder{
			reminder_id = column_int64(stmt, 0),
			todo_id     = column_int64(stmt, 1),
			user_id     = column_int64(stmt, 2),
			title       = column_string(stmt, 3),
			remind_at   = column_int64(stmt, 4),
			tg_chat_id  = column_int64(stmt, 5),
			webhook_url = column_string(stmt, 6),
		}
		append(&out, row)
	}
	return out[:], nil
}

// mark_reminder_fired sets fired=1 for the given reminder id.
mark_reminder_fired :: proc(db: Database, reminder_id: i64) {
	stmt, rc := prepare(db, "UPDATE reminders SET fired = 1 WHERE id = ?;")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, reminder_id)
	_ = step(stmt)
}

// mark_reminder_failed increments retry_count. If retries exceed max, marks as fired
// to prevent infinite retries.
mark_reminder_failed :: proc(db: Database, reminder_id: i64, max_retries: int = 3) {
	// First increment retry_count.
	stmt, rc := prepare(db, "UPDATE reminders SET retry_count = retry_count + 1 WHERE id = ?;")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, reminder_id)
	_ = step(stmt)

	// Check if we should give up.
	stmt2, rc2 := prepare(db, "SELECT retry_count FROM reminders WHERE id = ?;")
	if rc2 != OK do return
	defer finalize_safe(stmt2)
	_ = bind_int64(stmt2, 1, reminder_id)
	if !step_row(stmt2) do return
	retries := int(column_int64(stmt2, 0))
	if retries >= max_retries {
		mark_reminder_fired(db, reminder_id)
	}
}

// === Webhook URL management ===

// get_user_webhook returns the webhook URL for a user ("" if not set).
get_user_webhook :: proc(db: Database, user_id: i64) -> string {
	stmt, rc := prepare(db, "SELECT webhook_url FROM users WHERE id = ?;")
	if rc != OK do return ""
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, user_id)
	if !step_row(stmt) do return ""
	if column_type(stmt, 0) == TYPE_NULL do return ""
	return column_string(stmt, 0)
}

// set_user_webhook sets the webhook URL for a user.
set_user_webhook :: proc(db: Database, user_id: i64, url: string) -> DB_Error {
	stmt, rc := prepare(db, "UPDATE users SET webhook_url = ? WHERE id = ?;")
	if rc != OK {
		return fmt.tprintf("set_user_webhook prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)
	_ = bind_string(stmt, 1, url)
	_ = bind_int64(stmt, 2, user_id)
	rc = step(stmt)
	if rc != DONE {
		return fmt.tprintf("set_user_webhook step failed: %s", err_str(db))
	}
	return nil
}

// set_user_tg_chat sets the Telegram chat_id for a user (links web session to TG account).
set_user_tg_chat :: proc(db: Database, user_id: i64, chat_id: i64) {
	stmt, rc := prepare(db, "UPDATE users SET tg_chat_id = ? WHERE id = ?;")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, chat_id)
	_ = bind_int64(stmt, 2, user_id)
	_ = step(stmt)
}

// === Upcoming reminders listing ===

// Upcoming_Reminder is a reminder that hasn't fired yet.
Upcoming_Reminder :: struct {
	reminder_id: i64,
	todo_id:     i64,
	title:       string,
	remind_at:   i64,
}

// list_upcoming_reminders returns unfired reminders for a user, sorted by time.
list_upcoming_reminders :: proc(db: Database, user_id: i64) -> (rows: []Upcoming_Reminder, err: DB_Error) {
	stmt, rc := prepare(db, `
SELECT r.id, r.todo_id, t.title, r.remind_at
FROM reminders r
JOIN todos t ON r.todo_id = t.id
WHERE r.user_id = ? AND r.fired = 0
ORDER BY r.remind_at ASC;
`)
	if rc != OK {
		return nil, fmt.tprintf("list_upcoming_reminders prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)

	out := make([dynamic]Upcoming_Reminder, 0, 8, context.temp_allocator)
	for step_row(stmt) {
		row := Upcoming_Reminder{
			reminder_id = column_int64(stmt, 0),
			todo_id     = column_int64(stmt, 1),
			title       = column_string(stmt, 2),
			remind_at   = column_int64(stmt, 3),
		}
		append(&out, row)
	}
	return out[:], nil
}
