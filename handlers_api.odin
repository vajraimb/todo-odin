package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"

import "ai"
import "store"
import "web"

// === JSON API (/api/v1) ===
//
// All endpoints require a valid session (same cookie as the web UI).
// P5 will add proper API tokens.
//
// Endpoints:
//   GET    /api/v1/todos           — list todos (optional ?filter=all|active|completed)
//   POST   /api/v1/todos           — create todo { "title": "..." }
//   PATCH  /api/v1/todos/:id       — update { "title"?, "completed"? }
//   DELETE /api/v1/todos/:id       — delete todo
//   POST   /api/v1/todos/toggle    — toggle all
//   DELETE /api/v1/todos/completed — delete all completed
//   GET    /api/v1/todos/count     — { total, active, completed }

// JSON request/response structs. Field names use snake_case via json tags.

API_Todo :: struct {
	id:        i64  `json:"id"`,
	title:     string `json:"title"`,
	completed: bool `json:"completed"`,
}

API_Create_Req :: struct {
	title: string `json:"title"`,
}

API_Update_Req :: struct {
	title:     Maybe(string) `json:"title"`,
	completed: Maybe(bool)   `json:"completed"`,
}

API_Counts :: struct {
	total:     int `json:"total"`,
	active:    int `json:"active"`,
	completed: int `json:"completed"`,
}

API_Error :: struct {
	error: string `json:"error"`,
}

// _api_require_session extracts the session OR validates an API token.
// For API routes, we accept either:
//   1. Session cookie (same as web UI)
//   2. Authorization: Bearer <token> header
// Returns the user_id, or responds with 401 if unauthorized.
_api_require_session :: proc(req: ^web.Request, res: ^web.Response) -> ^Session {
	// Try session cookie first.
	session := session_of_req(req)
	if session != nil do return session

	// Try Bearer token.
	auth_header, has_auth := web.headers_get(req.headers[:], "authorization")
	if has_auth && strings.has_prefix(auth_header, "Bearer ") {
		token := strings.trim_prefix(auth_header, "Bearer ")
		if uid, found := store.lookup_api_token(store.DB, token); found {
			// Create a temp Session for this request.
			s := new(Session, context.temp_allocator)
			s.user_id = uid
			req.user_ptr = s
			return s
		}
	}

	_api_error(res, web.S_401_UNAUTHORIZED, "unauthorized")
	return nil
}

// _api_error responds with a JSON error object.
_api_error :: proc(res: ^web.Response, status: web.Status, msg: string) {
	body, _ := json.marshal(API_Error{error = msg}, allocator = context.temp_allocator)
	web.respond(res, status)
	web.set_content_type(res, .Json)
	web.write_bytes(res, body)
}

// _api_json responds with a JSON-serialized value.
_api_json :: proc(res: ^web.Response, status: web.Status, v: any) {
	body, err := json.marshal(v, allocator = context.temp_allocator)
	if err != nil {
		log.errorf("json marshal failed: %v", err)
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "internal error")
		return
	}
	web.respond(res, status)
	web.set_content_type(res, .Json)
	web.write_bytes(res, body)
}

// _api_row_to_json converts a store.Todo_Row to API_Todo.
_api_row_to_json :: proc(row: store.Todo_Row) -> API_Todo {
	return API_Todo{
		id = row.id,
		title = row.title,
		completed = row.completed,
	}
}

// === Handlers ===

api_list_todos :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	filter := store.Todo_Filter.All
	if f, ok := web.headers_get(req.headers[:], "x-filter"); ok {
		switch f {
		case "active":    filter = .Active
		case "completed": filter = .Completed
		}
	}
	// Also accept ?filter= via query string.
	if q := req.query; len(q) > 0 {
		if val, ok := _query_param(q, "filter"); ok {
			switch val {
			case "active":    filter = .Active
			case "completed": filter = .Completed
			}
		}
	}

	rows, err := store.list_todos(store.DB, session.user_id, filter)
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to list todos")
		return
	}

	todos := make([]API_Todo, len(rows), context.temp_allocator)
	for row, i in rows {
		todos[i] = _api_row_to_json(row)
	}
	_api_json(res, web.S_200_OK, todos)
}

api_create_todo :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	if len(req.body) == 0 {
		_api_error(res, web.S_400_BAD_REQUEST, "empty body")
		return
	}

	body_req: API_Create_Req
	if err := json.unmarshal(req.body, &body_req); err != nil {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, fmt.tprintf("invalid JSON: %v", err))
		return
	}

	if len(body_req.title) == 0 {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "title is required")
		return
	}

	// When AI is configured, parse the input for title + optional reminder.
	parsed_title := body_req.title
	parsed_remind: Maybe(string) = nil
	if ai.configured() {
		now := time.now()
		year, month, day := time.date(now)
		hour, minute, second := time.clock(now)
		now_iso := fmt.tprintf("{}-{:02}-{:02}T{:02}:{:02}:{:02}", year, int(month), day, hour, minute, second)
		parsed, ok := ai.parse_todo(body_req.title, now_iso)
		if ok && len(parsed.title) > 0 {
			parsed_title = parsed.title
			parsed_remind = parsed.remind_at
		}
	}

	todo_id, err := store.create_todo(store.DB, session.user_id, parsed_title)
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to create todo")
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
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "created todo not found")
		return
	}

	_api_json(res, web.S_201_CREATED, _api_row_to_json(row))
}

api_update_todo :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	int_id, ok := strconv.parse_i64(req.url_params[0], 10)
	if !ok || int_id < 0 {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "invalid id")
		return
	}

	if len(req.body) == 0 {
		_api_error(res, web.S_400_BAD_REQUEST, "empty body")
		return
	}

	body_req: API_Update_Req
	if err := json.unmarshal(req.body, &body_req); err != nil {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, fmt.tprintf("invalid JSON: %v", err))
		return
	}

	// Check the todo exists and belongs to the user.
	row, found := store.get_todo(store.DB, session.user_id, int_id)
	if !found {
		_api_error(res, web.S_404_NOT_FOUND, "todo not found")
		return
	}

	title := row.title
	has_title := false
	if t, ok := body_req.title.?; ok {
		title = t
		has_title = true
		if len(title) == 0 {
			_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "title cannot be empty")
			return
		}
	}

	completed := row.completed
	if c, ok := body_req.completed.?; ok {
		completed = c
	}

	err := store.update_todo(store.DB, session.user_id, int_id, title, has_title, completed)
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to update todo")
		return
	}

	// Fetch updated row.
	row, found = store.get_todo(store.DB, session.user_id, int_id)
	if !found {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "updated todo not found")
		return
	}

	_api_json(res, web.S_200_OK, _api_row_to_json(row))
}

api_delete_todo :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	int_id, ok := strconv.parse_i64(req.url_params[0], 10)
	if !ok || int_id < 0 {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "invalid id")
		return
	}

	deleted := store.delete_todo(store.DB, session.user_id, int_id)
	if !deleted {
		_api_error(res, web.S_404_NOT_FOUND, "todo not found")
		return
	}

	web.respond(res, web.S_204_NO_CONTENT)
}

api_toggle_all :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	all_done := store.all_todos_completed(store.DB, session.user_id)
	_ = store.set_all_completed(store.DB, session.user_id, !all_done)

	total, active, completed := store.todo_counts(store.DB, session.user_id)
	_api_json(res, web.S_200_OK, API_Counts{total = total, active = active, completed = completed})
}

api_clean_completed :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	_ = store.delete_completed_todos(store.DB, session.user_id)

	total, active, completed := store.todo_counts(store.DB, session.user_id)
	_api_json(res, web.S_200_OK, API_Counts{total = total, active = active, completed = completed})
}

api_counts :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	total, active, completed := store.todo_counts(store.DB, session.user_id)
	_api_json(res, web.S_200_OK, API_Counts{total = total, active = active, completed = completed})
}

// _query_param extracts a key=value pair from a query string.
_query_param :: proc(query: string, key: string) -> (string, bool) {
	// Simple parser: split by '&' then find key=.
	start: int = 0
	s := query
	for c, i in transmute([]u8)s {
		if c == '&' {
			if v, ok := _match_param(s[start:i], key); ok do return v, true
			start = i + 1
		}
	}
	if v, ok := _match_param(s[start:], key); ok do return v, true
	return "", false
}

_match_param :: proc(pair: string, key: string) -> (string, bool) {
	eq := -1
	for c, i in transmute([]u8)pair {
		if c == '=' {
			eq = i
			break
		}
	}
	if eq < 0 do return "", false
	if pair[:eq] != key do return "", false
	return pair[eq+1:], true
}

// === API Token management ===

API_Token_Create_Req :: struct {
	name: string `json:"name"`,
}

API_Token_Create_Resp :: struct {
	token: string `json:"token"`,
	name:  string `json:"name"`,
}

API_Token_List_Item :: struct {
	id:           i64    `json:"id"`,
	name:         string `json:"name"`,
	created_at:   i64    `json:"created_at"`,
	last_used_at: i64    `json:"last_used_at"`,
}

// POST /api/v1/tokens — create a new API token
api_create_token :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	body_req: API_Token_Create_Req
	if len(req.body) > 0 {
		if err := json.unmarshal(req.body, &body_req); err != nil {
			_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "invalid JSON")
			return
		}
	}

	token, err := store.create_api_token(store.DB, session.user_id, body_req.name)
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to create token")
		return
	}

	_api_json(res, web.S_201_CREATED, API_Token_Create_Resp{token = token, name = body_req.name})
}

// GET /api/v1/tokens — list all API tokens for the user
api_list_tokens :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	tokens, err := store.list_api_tokens(store.DB, session.user_id)
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to list tokens")
		return
	}

	items := make([]API_Token_List_Item, len(tokens), context.temp_allocator)
	for t, i in tokens {
		items[i] = API_Token_List_Item{
			id = t.id,
			name = t.name,
			created_at = t.created_at,
			last_used_at = t.last_used_at,
		}
	}
	_api_json(res, web.S_200_OK, items)
}

// DELETE /api/v1/tokens/:id — delete an API token
api_delete_token :: proc(req: ^web.Request, res: ^web.Response) {
	session := _api_require_session(req, res)
	if session == nil do return

	token_id, ok := strconv.parse_i64(req.url_params[0], 10)
	if !ok || token_id < 0 {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "invalid id")
		return
	}

	deleted := store.delete_api_token(store.DB, session.user_id, token_id)
	if !deleted {
		_api_error(res, web.S_404_NOT_FOUND, "token not found")
		return
	}

	web.respond(res, web.S_204_NO_CONTENT)
}
