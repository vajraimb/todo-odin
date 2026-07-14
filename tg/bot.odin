package tg

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

import "../ai"
import "../store"

// start_bot launches the Telegram bot in a background thread.
// Returns false if no token is configured.
start_bot :: proc() -> bool {
	if !init_token() {
		log.info("no TG_BOT_TOKEN set; Telegram bot disabled")
		return false
	}

	log.info("Telegram bot starting...")
	thread.run(_bot_loop)
	return true
}

// consume_login_token is called by the web handler to verify a login token.
// Delegates to the DB-backed store.
consume_login_token :: proc(token: string) -> (i64, bool) {
	return store.consume_login_token(store.DB, token)
}

// _bot_loop is the main long-polling loop. Runs forever in a background thread.
_bot_loop :: proc() {
	// Set up our own logger (the thread doesn't inherit the parent's context).
	context.logger = log.create_console_logger(
		.Info,
		log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color, .Thread_Id},
	)

	offset: i64 = 0
	TIMEOUT :: 30  // long-poll timeout in seconds

	for {
		updates, ok := get_updates(offset, TIMEOUT)
		if !ok {
			time.sleep(time.Second * 5)
			free_all(context.temp_allocator)
			continue
		}

		for update in updates {
			offset = update.update_id + 1
			_handle_update(update)
		}

		// Free temp allocations from this iteration to prevent unbounded growth.
		free_all(context.temp_allocator)
	}
}

// _handle_update processes a single TG update (message).
_handle_update :: proc(update: TG_Update) {
	msg, ok := update.message.?
	if !ok do return

	chat_id := msg.chat.id
	text := strings.trim_space(msg.text)

	// Get the user's name for display.
	display_name := "TG user"
	if user, ok := msg.from.?; ok {
		if len(user.first_name) > 0 {
			display_name = user.first_name
		}
	}

	// Find or create the user in our DB.
	user_id, err := store.find_or_create_tg_user(store.DB, chat_id, display_name)
	if err != nil {
		log.errorf("find_or_create_tg_user failed: %v", err)
		send_message(chat_id, "Internal error. Please try again later.")
		return
	}

	log.infof("TG [%s, chat={}]: {}", display_name, chat_id, text)

	// Parse the command.
	// Check for voice message first.
	if voice, has_voice := msg.voice.?; has_voice {
		_handle_voice(chat_id, user_id, voice)
		return
	}

	if len(text) == 0 || text[0] != '/' {
		// Non-command message: use LLM to parse, then create todo.
		if len(text) > 0 {
			_handle_natural_text(chat_id, user_id, text)
		}
		return
	}

	// Split command and args.
	cmd_end := strings.index_byte(text, ' ')
	cmd: string
	args: string
	if cmd_end >= 0 {
		cmd = text[:cmd_end]
		args = strings.trim_space(text[cmd_end+1:])
	} else {
		cmd = text
		args = ""
	}

	switch cmd {
	case "/start", "/help":
		_handle_help(chat_id)
	case "/add", "/new":
		if ai.configured() {
			_create_todo_from_text(chat_id, user_id, args)
		} else {
			_handle_add(chat_id, user_id, args)
		}
	case "/list", "/ls":
		_handle_list(chat_id, user_id)
	case "/done":
		_handle_done(chat_id, user_id, args)
	case "/undone":
		_handle_undone(chat_id, user_id, args)
	case "/delete", "/del", "/rm":
		_handle_delete(chat_id, user_id, args)
	case "/count":
		_handle_count(chat_id, user_id)
	case "/webhook":
		_handle_webhook(chat_id, user_id, args)
	case "/reminders":
		_handle_reminders(chat_id, user_id)
	case "/web":
		_handle_web_login(chat_id, user_id)
	case "/share":
		_handle_share(chat_id, user_id, args)
	case "/unshare":
		_handle_unshare(chat_id, user_id, args)
	case:
		send_message(chat_id, fmt.tprintf("Unknown command: {}\nUse /help for available commands.", cmd))
	}
}

// === Command handlers ===

_handle_help :: proc(chat_id: i64) {
	help := `Todo Bot Commands:

/add <text> — create todo (AI parses natural language)
/list — show all todos
/done <id> — mark completed
/undone <id> — mark active
/delete <id> — delete todo
/count — show counts
/reminders — show upcoming reminders
/webhook <url> — set your Bark URL
/share <id> <bark_url> — share reminder to another Bark
/unshare <id> <bark_url> — remove shared recipient
/web — get web login link

Send text or voice to create todos.`

	send_message(chat_id, help)
}

// _handle_share adds an additional Bark webhook to a reminder.
// Usage: /share <todo_id> https://api.day.app/child_key
// Optional label: /share <todo_id> https://api.day.app/key 儿子
_handle_share :: proc(chat_id: i64, user_id: i64, args: string) {
	// Parse: <todo_id> <url> [label...]
	parts := strings.fields(args)
	if len(parts) < 2 {
		send_message(chat_id, "Usage: /share <todo_id> <bark_url> [label]\n\nExample:\n/share 5 https://api.day.app/xxxx 儿子")
		return
	}

	todo_id, ok := strconv.parse_i64(parts[0], 10)
	if !ok {
		send_message(chat_id, "Invalid todo ID.")
		return
	}

	webhook_url := parts[1]
	if !strings.has_prefix(webhook_url, "http") {
		send_message(chat_id, "URL must start with http:// or https://")
		return
	}

	label := ""
	if len(parts) > 2 {
		// Join remaining parts as label
		lbl := make([dynamic]u8, 0, 64, context.temp_allocator)
		for i in 2..<len(parts) {
			if i > 2 do append(&lbl, ' ')
			append(&lbl, ..transmute([]u8)parts[i])
		}
		label = transmute(string)(lbl[:])
	}

	// Find the reminder for this todo.
	reminder_id, found := store.find_reminder_by_todo(store.DB, user_id, todo_id)
	if !found {
		send_message(chat_id, fmt.tprintf("No active reminder for todo #{}. Create one with /add first.", todo_id))
		return
	}

	err := store.add_reminder_recipient(store.DB, reminder_id, webhook_url, label)
	if err != nil {
		send_message(chat_id, fmt.tprintf("Failed to add: {}", err))
		return
	}

	display := webhook_url
	if len(label) > 0 {
		display = fmt.tprintf("{} ({})", label, webhook_url)
	}
	send_message(chat_id, fmt.tprintf("✅ Shared reminder for #{} to:\n{}\n\nThey'll get a Bark push when it fires.", todo_id, display))
}

// _handle_unshare removes a shared Bark webhook from a reminder.
_handle_unshare :: proc(chat_id: i64, user_id: i64, args: string) {
	parts := strings.fields(args)
	if len(parts) < 2 {
		send_message(chat_id, "Usage: /unshare <todo_id> <bark_url>")
		return
	}

	todo_id, ok := strconv.parse_i64(parts[0], 10)
	if !ok {
		send_message(chat_id, "Invalid todo ID.")
		return
	}

	webhook_url := parts[1]
	reminder_id, found := store.find_reminder_by_todo(store.DB, user_id, todo_id)
	if !found {
		send_message(chat_id, fmt.tprintf("No reminder for todo #{}.", todo_id))
		return
	}

	removed := store.remove_reminder_recipient(store.DB, reminder_id, webhook_url)
	if removed {
		send_message(chat_id, fmt.tprintf("Removed recipient from todo #{}.", todo_id))
	} else {
		send_message(chat_id, "Recipient not found.")
	}
}

// _handle_web_login generates a one-time login link and sends it via TG.
// Stores the token in the DB (not in-memory) for thread safety.
_handle_web_login :: proc(chat_id: i64, user_id: i64) {
	token := store.generate_login_token(user_id)
	public_url := os.lookup_env_alloc("PUBLIC_URL", context.allocator) or_else "https://todo.vajraodin.ai"
	login_url := fmt.tprintf("{}/login?token={}", public_url, token)
	log.infof("generated login token '{}' for user {}", token, user_id)
	send_message(chat_id, fmt.tprintf(
		"Click to log in on the web:\n\n{}",
		login_url,
	))
}

_random_token :: proc(n: int) -> string {
	chars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	out := make([]u8, n, context.temp_allocator)
	for i in 0..<n {
		out[i] = chars[rand.int_max(len(chars))]
	}
	return transmute(string)(out)
}

_handle_add :: proc(chat_id: i64, user_id: i64, title: string) {
	if len(title) == 0 {
		send_message(chat_id, "Usage: /add <text>\nOr just send the text directly.")
		return
	}

	todo_id, err := store.create_todo(store.DB, user_id, title)
	if err != nil {
		send_message(chat_id, "Failed to create todo.")
		return
	}

	send_message(chat_id, fmt.tprintf("Created todo #{}: {}", todo_id, title))
}

_handle_list :: proc(chat_id: i64, user_id: i64) {
	rows, err := store.list_todos(store.DB, user_id, .Active)
	if err != nil {
		send_message(chat_id, "Failed to list todos.")
		return
	}

	if len(rows) == 0 {
		send_message(chat_id, "No active todos! All done 🎉")
		return
	}

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "Active todos:\n")
	for row in rows {
		strings.write_string(&sb, fmt.tprintf("\n○ #{} {}", row.id, row.title))
	}

	send_message(chat_id, strings.to_string(sb))
}

_handle_done :: proc(chat_id: i64, user_id: i64, args: string) {
	id, ok := _parse_id(args)
	if !ok {
		send_message(chat_id, "Usage: /done <id>")
		return
	}

	row, found := store.get_todo(store.DB, user_id, id)
	if !found {
		send_message(chat_id, fmt.tprintf("Todo #{} not found.", id))
		return
	}

	err := store.update_todo(store.DB, user_id, id, row.title, false, true)
	if err != nil {
		send_message(chat_id, "Failed to update todo.")
		return
	}

	send_message(chat_id, fmt.tprintf("✓ Done: #{} {}", id, row.title))
}

_handle_undone :: proc(chat_id: i64, user_id: i64, args: string) {
	id, ok := _parse_id(args)
	if !ok {
		send_message(chat_id, "Usage: /undone <id>")
		return
	}

	row, found := store.get_todo(store.DB, user_id, id)
	if !found {
		send_message(chat_id, fmt.tprintf("Todo #{} not found.", id))
		return
	}

	err := store.update_todo(store.DB, user_id, id, row.title, false, false)
	if err != nil {
		send_message(chat_id, "Failed to update todo.")
		return
	}

	send_message(chat_id, fmt.tprintf("○ Undone: #{} {}", id, row.title))
}

_handle_delete :: proc(chat_id: i64, user_id: i64, args: string) {
	id, ok := _parse_id(args)
	if !ok {
		send_message(chat_id, "Usage: /delete <id>")
		return
	}

	row, found := store.get_todo(store.DB, user_id, id)
	if !found {
		send_message(chat_id, fmt.tprintf("Todo #{} not found.", id))
		return
	}

	deleted := store.delete_todo(store.DB, user_id, id)
	if !deleted {
		send_message(chat_id, "Failed to delete todo.")
		return
	}

	send_message(chat_id, fmt.tprintf("Deleted: #{} {}", id, row.title))
}

_handle_count :: proc(chat_id: i64, user_id: i64) {
	total, active, completed := store.todo_counts(store.DB, user_id)
	send_message(chat_id, fmt.tprintf("Total: {}\nActive: {}\nCompleted: {}", total, active, completed))
}

// _parse_id parses a numeric id from a string argument.
// Handles optional '#' prefix (e.g. "#1" -> 1).
_parse_id :: proc(s: string) -> (i64, bool) {
	trimmed := strings.trim_space(s)
	if len(trimmed) > 0 && trimmed[0] == '#' {
		trimmed = trimmed[1:]
	}
	trimmed = strings.trim_space(trimmed)
	if len(trimmed) == 0 do return 0, false
	return strconv.parse_i64(trimmed, 10)
}

// _local_time_iso returns the current time with explicit date context for the LLM.
_local_time_iso :: proc() -> string {
	offset_hours: i64 = 8
	if s, ok := os.lookup_env_alloc("TZ_OFFSET_HOURS", context.temp_allocator); ok {
		if n, pok := strconv.parse_i64(s, 10); pok {
			offset_hours = n
		}
	}

	now_unix := time.time_to_unix(time.now())
	local_unix := now_unix + offset_hours * 3600
	local_time := time.unix(local_unix, 0)

	year, month, day := time.date(local_time)
	hour, minute, second := time.clock(local_time)

	weekday_names := []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
	wd := int(time.weekday(local_time))

	// Also compute tomorrow and day after.
	tomorrow_unix := local_unix + 86400
	tomorrow := time.unix(tomorrow_unix, 0)
	t_y, t_m, t_d := time.date(tomorrow)

	day_after_unix := local_unix + 2 * 86400
	day_after := time.unix(day_after_unix, 0)
	da_y, da_m, da_d := time.date(day_after)

	return fmt.tprintf(
		"{}-{:02}-{:02} {:02}:{:02} ({})\nToday is {}-{:02}-{:02}.\nTomorrow is {}-{:02}-{:02}.\nDay after tomorrow is {}-{:02}-{:02}.",
		year, int(month), day, hour, minute, weekday_names[wd],
		year, int(month), day,
		t_y, int(t_m), t_d,
		da_y, int(da_m), da_d,
	)
}

// === Webhook & Reminders ===

// _handle_webhook sets or clears the user's webhook URL.
// Usage: /webhook https://example.com/hook  or  /webhook clear
_handle_webhook :: proc(chat_id: i64, user_id: i64, args: string) {
	url := strings.trim_space(args)

	if len(url) == 0 || url == "clear" || url == "off" || url == "none" {
		err := store.set_user_webhook(store.DB, user_id, "")
		if err != nil {
			send_message(chat_id, "Failed to clear webhook.")
			return
		}
		send_message(chat_id, "Webhook cleared. Reminders will only be sent via Telegram.")
		return
	}

	// Basic validation: must start with http.
	if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") {
		send_message(chat_id, "Webhook URL must start with http:// or https://\n\nExample:\n/webhook https://api.day.app/YOUR_KEY\n/webhook https://ntfy.sh/your_topic")
		return
	}

	err := store.set_user_webhook(store.DB, user_id, url)
	if err != nil {
		send_message(chat_id, "Failed to set webhook.")
		return
	}

	send_message(chat_id, fmt.tprintf(
		"Webhook set! When a reminder fires, I'll POST to:\n{}\n\nPayload: {{\"title\":\"...\",\"remind_at\":timestamp}}\n\nWorks with: Bark, ntfy.sh, iOS Shortcuts, etc.",
		url,
	))
}

// _handle_reminders lists upcoming (unfired) reminders.
_handle_reminders :: proc(chat_id: i64, user_id: i64) {
	reminders, err := store.list_upcoming_reminders(store.DB, user_id)
	if err != nil {
		send_message(chat_id, "Failed to list reminders.")
		return
	}

	if len(reminders) == 0 {
		send_message(chat_id, "No upcoming reminders.")
		return
	}

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "Upcoming reminders:\n")
	for r in reminders {
		// Format the remind_at timestamp as a readable date.
		t := time.unix(r.remind_at, 0)
		year, month, day := time.date(t)
		hour, minute, _ := time.clock(t)
		strings.write_string(&sb, fmt.tprintf(
			"\n⏰ #{} {} — {:04}-{:02}-{:02} {:02}:{:02}",
			r.todo_id, r.title, year, int(month), day, hour, minute,
		))
	}

	send_message(chat_id, strings.to_string(sb))
}

// === Voice & AI handlers ===

// _handle_voice processes a voice message: download → transcribe → parse → create todo.
_handle_voice :: proc(chat_id: i64, user_id: i64, voice: TG_Voice) {
	if !ai.configured() {
		send_message(chat_id, "Voice messages require AI to be configured. Set AI_API_KEY.")
		return
	}

	// Step 1: Get the file path from TG.
	file_path, file_ok := get_file(voice.file_id)
	if !file_ok {
		send_message(chat_id, "Failed to get voice file info.")
		return
	}

	// Step 2: Download the voice file.
	url := download_file_url(file_path)
	local_path := fmt.tprintf("/tmp/tg_voice_{}.ogg", voice.file_id)
	defer os.remove(local_path)

	if !ai.http_download(url, local_path) {
		send_message(chat_id, "Failed to download voice file.")
		return
	}

	log.infof("voice downloaded: {} ({}s)", local_path, voice.duration)

	// Step 3: Transcribe via Whisper API.
	text, transcribed := ai.transcribe_audio(local_path)
	if !transcribed {
		send_message(chat_id, "Failed to transcribe voice message.")
		return
	}

	log.infof("voice transcribed: {}", text)
	if len(text) == 0 {
		send_message(chat_id, "Voice message was empty.")
		return
	}

	// Step 4: Parse with LLM and create todo.
	send_message(chat_id, fmt.tprintf("Transcribed: {}", text))
	_create_todo_from_text(chat_id, user_id, text)
}

// _handle_natural_text uses the LLM to parse natural language into a todo (+reminder).
_handle_natural_text :: proc(chat_id: i64, user_id: i64, text: string) {
	if !ai.configured() {
		// Fallback: just create a todo with the raw text.
		_handle_add(chat_id, user_id, text)
		return
	}

	_create_todo_from_text(chat_id, user_id, text)
}

// _create_todo_from_text uses the LLM to parse text, creates the todo and optional reminder.
_create_todo_from_text :: proc(chat_id: i64, user_id: i64, text: string) {
	// Only use LLM if the text looks like it contains a time reference.
	needs_llm := _has_time_reference(text)

	parsed_title := text
	parsed_remind: Maybe(string) = nil

	if needs_llm && ai.configured() {
		now_iso := _local_time_iso()
		parsed, ok := ai.parse_todo(text, now_iso)
		if ok && len(parsed.title) > 0 {
			parsed_title = parsed.title
			parsed_remind = parsed.remind_at
		}
	}

	todo_id, err := store.create_todo(store.DB, user_id, parsed_title)
	if err != nil {
		send_message(chat_id, "Failed to create todo.")
		return
	}

	// If there's a reminder, store it.
	reminder_msg := ""
	if remind_iso, has_reminder := parsed_remind.?; has_reminder {
		if remind_unix, ok := store.parse_iso_to_unix(remind_iso); ok {
			// LLM returns local time; subtract offset to get UTC.
			offset_hours: i64 = 8
			if s, ok := os.lookup_env_alloc("TZ_OFFSET_HOURS", context.temp_allocator); ok {
				if n, pok := strconv.parse_i64(s, 10); pok {
					offset_hours = n
				}
			}
			remind_unix -= offset_hours * 3600

			now := store.now_unix()
			if remind_unix <= now {
				reminder_msg = fmt.tprintf("\n⚠️ Time already passed ({})", remind_iso)
			} else if remind_unix > now + 365 * 86400 {
				// Reject dates more than 1 year in the future (likely LLM error).
				reminder_msg = "\n⚠️ Date seems wrong, no reminder set."
			} else {
				_, rerr := store.create_reminder(store.DB, todo_id, user_id, remind_unix)
				if rerr != nil {
					log.errorf("create_reminder failed: %v", rerr)
				} else {
					reminder_msg = fmt.tprintf("\n⏰ Reminder: {}", remind_iso)
				}
			}
		}
	}

	send_message(chat_id, fmt.tprintf("Created todo #{}: {}{}", todo_id, parsed_title, reminder_msg))
}

// _has_time_reference checks if the text contains clear time-related keywords.
_has_time_reference :: proc(text: string) -> bool {
	keywords := []string{
		"明天", "今天", "后天", "下周", "提醒",
		"早上", "晚上", "上午", "下午", "点半", "点钟",
		"tomorrow", "today", "tonight", "next week", "remind",
		"morning", "evening", "noon",
		"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
	}
	for kw in keywords {
		if strings.contains(text, kw) do return true
	}
	return false
}
