package scheduler

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

import "../store"
import "../tg"

// SCAN_INTERVAL is how often the scheduler checks for due reminders.
SCAN_INTERVAL :: 30 * time.Second

// start_reminders launches the reminder scheduler in a background thread.
start_reminders :: proc() {
	log.info("Reminder scheduler starting...")
	thread.run(_scheduler_loop)
}

// _scheduler_loop is the main scheduler loop. Runs forever.
_scheduler_loop :: proc() {
	context.logger = log.create_console_logger(
		.Info,
		log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color, .Thread_Id},
	)

	for {
		_fire_due_reminders()
		time.sleep(SCAN_INTERVAL)
		free_all(context.temp_allocator)
	}
}

// _fire_due_reminders queries the DB for due reminders and dispatches notifications.
_fire_due_reminders :: proc() {
	now := store.now_unix()
	reminders, err := store.list_due_reminders(store.DB, now)
	if err != nil {
		log.errorf("scheduler: list_due_reminders failed: %v", err)
		return
	}

	if len(reminders) == 0 do return

	log.infof("scheduler: {} reminder(s) due", len(reminders))

	for r in reminders {
		_fire_one(r)
	}
}

// _fire_one dispatches a single reminder via TG message + webhook.
_fire_one :: proc(r: store.Due_Reminder) {
	success := true

	// 1. Send TG message (if user has a chat_id).
	if r.tg_chat_id != 0 {
		msg := fmt.tprintf("⏰ Reminder: #{} {}", r.todo_id, r.title)
		if !tg.send_message(r.tg_chat_id, msg) {
			log.warnf("scheduler: TG send failed for reminder {}", r.reminder_id)
			success = false
		}
	}

	// 2. Call webhook (if user has one configured).
	if len(r.webhook_url) > 0 {
		if !_call_webhook(r.webhook_url, r.title, r.remind_at) {
			log.warnf("scheduler: webhook failed for reminder {}", r.reminder_id)
			// Don't mark as failure — TG message might have succeeded.
			// Webhook failures are less critical.
		}
	}

	// 3. Mark as fired (or increment retry on failure).
	if success {
		store.mark_reminder_fired(store.DB, r.reminder_id)
		log.infof("scheduler: fired reminder {} (todo #{})", r.reminder_id, r.todo_id)
	} else {
		store.mark_reminder_failed(store.DB, r.reminder_id)
		log.warnf("scheduler: marked reminder {} as failed", r.reminder_id)
	}
}

// _call_webhook POSTs a JSON payload to the user's webhook URL.
// Works with iOS Shortcuts, Bark, ntfy.sh, or any HTTP endpoint.
_call_webhook :: proc(url: string, title: string, remind_at: i64) -> bool {
	// Build a simple JSON payload.
	body := fmt.tprintf(
		`{{"title":{},"remind_at":{}}}`,
		_json_str(title),
		remind_at,
	)

	desc := os.Process_Desc{
		command = []string{
			"curl", "-s", "-X", "POST",
			"-H", "Content-Type: application/json",
			"-d", body,
			"-o", "/dev/null",  // discard response
			"-w", "%{http_code}",  // output HTTP status code
			url,
		},
	}
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || !state.exited {
		return false
	}

	// Check HTTP status code (2xx = success).
	status_str := strings.trim_space(string(stdout))
	status, ok := _parse_int(status_str)
	if !ok do return false
	return status >= 200 && status < 300
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

// _json_str escapes a string for JSON value inclusion.
_json_str :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	strings.write_byte(&sb, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':  strings.write_string(&sb, "\\\"")
		case '\\': strings.write_string(&sb, "\\\\")
		case '\n': strings.write_string(&sb, "\\n")
		case '\r': strings.write_string(&sb, "\\r")
		case '\t': strings.write_string(&sb, "\\t")
		case:
			if c < 0x20 {
				strings.write_string(&sb, fmt.tprintf("\\u{:04x}", c))
			} else {
				strings.write_byte(&sb, c)
			}
		}
	}
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}
