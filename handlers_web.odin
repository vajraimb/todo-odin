package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "ai"
import "store"
import "web"

// === Web (HTMX) Handlers ===
// These handlers return HTML fragments for HTMX-driven updates.

handler_index :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond_redirect(res, web.S_302_FOUND, "/")
		return
	}

	is_htmx := web.headers_has(req.headers[:], "hx-request")
	respond_list(res, !is_htmx, session.user_id, page_from_path(req.path))
}

handler_create_todo :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond(res, web.S_401_UNAUTHORIZED)
		return
	}

	body, ok := web.parse_url_encoded(req.body)
	if !ok {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	title := body["title"]
	if len(title) == 0 {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	// When AI is configured, parse the input for title + optional reminder.
	parsed_title := title
	parsed_remind: Maybe(string) = nil
	if ai.configured() {
		now_iso := _local_time_iso_web()
		parsed, ok := ai.parse_todo(title, now_iso)
		if ok && len(parsed.title) > 0 {
			parsed_title = parsed.title
			parsed_remind = parsed.remind_at
		}
	}

	todo_id, err := store.create_todo(store.DB, session.user_id, parsed_title)
	if err != nil {
		log.errorf("create_todo failed: %v", err)
		web.respond(res, web.S_500_INTERNAL_SERVER_ERROR)
		return
	}

	// Create reminder if the LLM extracted one.
	if remind_iso, has_reminder := parsed_remind.?; has_reminder {
		if remind_unix, ok := store.parse_iso_to_unix(remind_iso); ok {
			_, rerr := store.create_reminder(store.DB, todo_id, session.user_id, remind_unix)
			if rerr != nil {
				log.errorf("create_reminder failed: %v", rerr)
			}
		}
	}

	row, found := store.get_todo(store.DB, session.user_id, todo_id)
	if !found {
		web.respond(res, web.S_500_INTERNAL_SERVER_ERROR)
		return
	}

	todo := _row_to_todo(row)

	web.respond(res, web.S_200_OK)
	web.set_content_type(res, .Html)

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	current_url := web.headers_get(req.headers[:], "hx-current-url") or_else ""
	switch page_from_path(current_url) {
	case .All, .Active:
		render_todo(&sb, &todo)
		render_count(&sb, _count(session.user_id))
	case .Completed:
		render_count(&sb, _count(session.user_id))
	}
	web.write_string(res, strings.to_string(sb))
}

handler_todo_patch :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond(res, web.S_401_UNAUTHORIZED)
		return
	}

	body, ok := web.parse_url_encoded(req.body)
	if !ok {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	int_id, iok := strconv.parse_i64(req.url_params[0], 10)
	if !iok || int_id < 0 {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	title, has_title := body["title"]
	if has_title && len(title) == 0 {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	completed := (body["completed"] or_else "off") == "on"

	err := store.update_todo(store.DB, session.user_id, int_id, title, has_title, completed)
	if err != nil {
		log.errorf("update_todo failed: %v", err)
		web.respond(res, web.S_500_INTERNAL_SERVER_ERROR)
		return
	}

	row, found := store.get_todo(store.DB, session.user_id, int_id)
	if !found {
		web.respond(res, web.S_404_NOT_FOUND)
		return
	}
	todo := _row_to_todo(row)

	web.respond(res, web.S_200_OK)
	web.set_content_type(res, .Html)

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	current_url := web.headers_get(req.headers[:], "hx-current-url") or_else ""
	page := page_from_path(current_url)

	show_item: bool
	switch page {
	case .All:       show_item = true
	case .Completed: show_item = todo.completed
	case .Active:    show_item = !todo.completed
	}

	render_count(&sb, _count(session.user_id))
	if show_item {
		render_todo(&sb, &todo)
	}
	web.write_string(res, strings.to_string(sb))
}

handler_delete_todo :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond(res, web.S_401_UNAUTHORIZED)
		return
	}

	int_id, ok := strconv.parse_i64(req.url_params[0], 10)
	if !ok || int_id < 0 {
		web.respond(res, web.S_422_UNPROCESSABLE_CONTENT)
		return
	}

	_ = store.delete_todo(store.DB, session.user_id, int_id)

	web.respond(res, web.S_200_OK)
	web.set_content_type(res, .Html)

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	render_count(&sb, _count(session.user_id))
	web.write_string(res, strings.to_string(sb))
}

handler_toggle :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond(res, web.S_401_UNAUTHORIZED)
		return
	}

	all_done := store.all_todos_completed(store.DB, session.user_id)
	_ = store.set_all_completed(store.DB, session.user_id, !all_done)

	current_url := web.headers_get(req.headers[:], "hx-current-url") or_else ""
	respond_list(res, false, session.user_id, page_from_path(current_url))
}

handler_clean :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond(res, web.S_401_UNAUTHORIZED)
		return
	}

	_ = store.delete_completed_todos(store.DB, session.user_id)

	current_url := web.headers_get(req.headers[:], "hx-current-url") or_else ""
	respond_list(res, false, session.user_id, page_from_path(current_url))
}

// === Shared helpers ===

respond_list :: proc(res: ^web.Response, full_page: bool, user_id: i64, page: Page) {
	filter := _filter_for_page(page)
	rows, err := store.list_todos(store.DB, user_id, filter)
	if err != nil {
		log.errorf("list_todos failed: %v", err)
		web.respond(res, web.S_500_INTERNAL_SERVER_ERROR)
		return
	}

	todos := make([]^Todo, len(rows), context.temp_allocator)
	for row, i in rows {
		t := new(Todo, context.temp_allocator)
		t^ = _row_to_todo(row)
		todos[i] = t
	}

	total, active, completed := store.todo_counts(store.DB, user_id)

	l := List{
		todos = todos,
		count = Count{
			total = total,
			active = active,
			completed = completed,
			oob = false,
		},
		page = page,
	}

	html := render_index(l) if full_page else _render_list_only(l)
	web.respond_html(res, web.S_200_OK, html)
}

_render_list_only :: proc(l: List) -> string {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	render_list(&sb, l)
	return strings.to_string(sb)
}

_count :: proc(user_id: i64) -> Count {
	total, active, completed := store.todo_counts(store.DB, user_id)
	return Count{
		total = total,
		active = active,
		completed = completed,
		oob = true,
	}
}

_filter_for_page :: proc(page: Page) -> store.Todo_Filter {
	switch page {
	case .All:       return .All
	case .Active:    return .Active
	case .Completed: return .Completed
	}
	return .All
}

_row_to_todo :: proc(row: store.Todo_Row) -> Todo {
	return Todo{
		id = int(row.id),
		title = row.title,
		completed = row.completed,
	}
}

// _local_time_iso_web returns current time in local timezone for the LLM.
_local_time_iso_web :: proc() -> string {
	offset_hours := 8
	if s, ok := os.lookup_env_alloc("TZ_OFFSET_HOURS", context.temp_allocator); ok {
		if n, ok := strconv.parse_int(s); ok {
			offset_hours = int(n)
		}
	}
	now_utc := time.now()
	now_unix := time.time_to_unix(now_utc)
	now_local_unix := now_unix + i64(offset_hours) * 3600
	now_local := time.unix(now_local_unix, 0)
	year, month, day := time.date(now_local)
	hour, minute, second := time.clock(now_local)
	weekday_names := []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
	weekday := weekday_names[int(time.weekday(now_local))]
	return fmt.tprintf("{}-{:02}-{:02}T{:02}:{:02}:{:02} ({}, UTC{})",
		year, int(month), day, hour, minute, second, weekday, offset_hours >= 0 ? "+" : "", offset_hours)
}
