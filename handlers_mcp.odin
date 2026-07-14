package main

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "ai"
import "store"
import "web"

// === MCP (Model Context Protocol) Server ===
//
// Minimal MCP server over HTTP (streamable HTTP transport).
// Endpoint: POST /mcp
//
// Supports:
//   - initialize: handshake
//   - tools/list: returns available tools
//   - tools/call: executes a tool
//
// Auth: same as API (session cookie or Bearer token).

// MCP types
MCP_Request :: struct {
	jsonrpc: string                 `json:"jsonrpc"`,
	id:      json.Value             `json:"id"`,
	method:  string                 `json:"method"`,
	params:  Maybe(json.Value)      `json:"params"`,
}

MCP_Error :: struct {
	code:    int    `json:"code"`,
	message: string `json:"message"`,
}

MCP_Tool :: struct {
	name:        string             `json:"name"`,
	description: string             `json:"description"`,
	inputSchema: json.Value         `json:"inputSchema"`,
}

// mcp_handle processes a single MCP JSON-RPC request.
mcp_handle :: proc(req: ^web.Request, res: ^web.Response) {
	// Auth: session cookie, Bearer token, OR ?token= query param (for MCP clients without header support).
	session := session_of_req(req)
	if session == nil {
		// Try Bearer token
		auth_header, has_auth := web.headers_get(req.headers[:], "authorization")
		if has_auth && strings.has_prefix(auth_header, "Bearer ") {
			token := strings.trim_prefix(auth_header, "Bearer ")
			if uid, found := store.lookup_api_token(store.DB, token); found {
				s := new(Session, context.temp_allocator)
				s.user_id = uid
				req.user_ptr = s
				session = s
			}
		}
	}
	// Try query param ?token=XXX
	if session == nil {
		if token, ok := _query_param(req.query, "token"); ok && len(token) > 0 {
			if uid, found := store.lookup_api_token(store.DB, token); found {
				s := new(Session, context.temp_allocator)
				s.user_id = uid
				req.user_ptr = s
				session = s
			}
		}
	}
	if session == nil {
		_api_error(res, web.S_401_UNAUTHORIZED, "unauthorized")
		return
	}

	if len(req.body) == 0 {
		_mcp_error(res, 0, -32600, "invalid request: empty body")
		return
	}

	mcp_req: MCP_Request
	if err := json.unmarshal(req.body, &mcp_req); err != nil {
		_mcp_error(res, 0, -32700, fmt.tprintf("parse error: %v", err))
		return
	}

	switch mcp_req.method {
	case "initialize":
		_mcp_initialize(res, mcp_req.id)
	case "tools/list":
		_mcp_tools_list(res, mcp_req.id, session.user_id)
	case "tools/call":
		_mcp_tools_call(res, mcp_req.id, mcp_req.params, session.user_id)
	case:
		_mcp_error(res, mcp_req.id, -32601, fmt.tprintf("method not found: {}", mcp_req.method))
	}
}

// _mcp_initialize returns the server capabilities.
_mcp_initialize :: proc(res: ^web.Response, id: json.Value) {
	result := `{
  "protocolVersion": "2024-11-05",
  "capabilities": {
    "tools": {}
  },
  "serverInfo": {
    "name": "todo-app",
    "version": "1.0.0"
  }
}`
	_mcp_result(res, id, result)
}

// _mcp_tools_list returns the list of available tools.
_mcp_tools_list :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	result := `{
  "tools": [
    {
      "name": "list_todos",
      "description": "List all todos for the current user. Optionally filter by status.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "filter": {"type": "string", "enum": ["active", "completed"], "default": "active", "description": "Which todos to show. Default: active (unfinished only)."}
        }
      }
    },
    {
      "name": "create_todo",
      "description": "Create a new todo. When AI is enabled, natural language is parsed for title + reminder (e.g. 'buy milk tomorrow 3pm').",
      "inputSchema": {
        "type": "object",
        "properties": {
          "title": {"type": "string", "description": "Todo title or natural language description"}
        },
        "required": ["title"]
      }
    },
    {
      "name": "update_todo",
      "description": "Update a todo's title and/or completion status.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {"type": "integer"},
          "title": {"type": "string"},
          "completed": {"type": "boolean"}
        },
        "required": ["id"]
      }
    },
    {
      "name": "delete_todo",
      "description": "Delete a todo by id.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {"type": "integer"}
        },
        "required": ["id"]
      }
    },
    {
      "name": "get_counts",
      "description": "Get todo counts (total, active, completed).",
      "inputSchema": {"type": "object", "properties": {}}
    },
    {
      "name": "toggle_all",
      "description": "Toggle all todos between completed and active.",
      "inputSchema": {"type": "object", "properties": {}}
    },
    {
      "name": "clear_completed",
      "description": "Delete all completed todos.",
      "inputSchema": {"type": "object", "properties": {}}
    },
    {
      "name": "list_reminders",
      "description": "List upcoming (unfired) reminders.",
      "inputSchema": {"type": "object", "properties": {}}
    },
    {
      "name": "get_web_login_link",
      "description": "Generate a web login link for the current user. Returns a URL that links their web browser session to their account.",
      "inputSchema": {"type": "object", "properties": {}}
    },
    {
      "name": "share_reminder",
      "description": "Share a todo's reminder to another person's Bark push URL. When the reminder fires, both you and the recipient get a Bark push notification on their iPhone.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "todo_id": {"type": "integer", "description": "The todo ID that has a reminder"},
          "bark_url": {"type": "string", "description": "The recipient's Bark URL, e.g. https://api.day.app/their-key"},
          "label": {"type": "string", "description": "Optional label for the recipient, e.g. '儿子'"}
        },
        "required": ["todo_id", "bark_url"]
      }
    }
  ]
}`
	_mcp_result(res, id, result)
}

// _mcp_tools_call executes a tool call.
_mcp_tools_call :: proc(res: ^web.Response, id: json.Value, params: Maybe(json.Value), user_id: i64) {
	params_set, has_params := params.?
	if !has_params {
		_mcp_error(res, id, -32602, "missing params")
		return
	}

	params_map := params_set

	// params is {name: "...", arguments: {...}}
	// Re-marshal and parse into a struct.
	params_bytes, _ := json.marshal(params_map, allocator = context.temp_allocator)

	call_params: struct {
		name:      string                 `json:"name"`,
		arguments: map[string]json.Value  `json:"arguments"`,
	}
	if err := json.unmarshal(params_bytes, &call_params); err != nil {
		_mcp_error(res, id, -32602, fmt.tprintf("invalid params: %v", err))
		return
	}

	switch call_params.name {
	case "list_todos":
		_mcp_tool_list_todos(res, id, user_id, call_params.arguments)
	case "create_todo":
		_mcp_tool_create_todo(res, id, user_id, call_params.arguments)
	case "update_todo":
		_mcp_tool_update_todo(res, id, user_id, call_params.arguments)
	case "delete_todo":
		_mcp_tool_delete_todo(res, id, user_id, call_params.arguments)
	case "get_counts":
		_mcp_tool_get_counts(res, id, user_id)
	case "toggle_all":
		_mcp_tool_toggle_all(res, id, user_id)
	case "clear_completed":
		_mcp_tool_clear_completed(res, id, user_id)
	case "list_reminders":
		_mcp_tool_list_reminders(res, id, user_id)
	case "get_web_login_link":
		_mcp_tool_get_web_login_link(res, id, user_id)
	case "share_reminder":
		_mcp_tool_share_reminder(res, id, user_id, call_params.arguments)
	case:
		_mcp_error(res, id, -32602, fmt.tprintf("unknown tool: {}", call_params.name))
	}
}

// === Tool implementations ===

_mcp_tool_list_todos :: proc(res: ^web.Response, id: json.Value, user_id: i64, args: map[string]json.Value) {
	filter := store.Todo_Filter.Active
	if f, ok := args["filter"]; ok {
		if fs, fok := f.(string); fok {
			switch fs {
			case "all":       filter = .All
			case "completed": filter = .Completed
			case "active":    filter = .Active
			}
		}
	}

	rows, err := store.list_todos(store.DB, user_id, filter)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to list todos")
		return
	}

	todos := make([]API_Todo, len(rows), context.temp_allocator)
	for row, i in rows {
		todos[i] = API_Todo{id = row.id, title = row.title, completed = row.completed}
	}
	_mcp_tool_result(res, id, todos)
}

_mcp_tool_create_todo :: proc(res: ^web.Response, id: json.Value, user_id: i64, args: map[string]json.Value) {
	title_val, ok := args["title"]
	if !ok {
		_mcp_error(res, id, -32602, "missing 'title' argument")
		return
	}
	title, tok := title_val.(string)
	if !tok || len(title) == 0 {
		_mcp_error(res, id, -32602, "title must be a non-empty string")
		return
	}

	parsed_title := title
	parsed_remind: Maybe(string) = nil
	if ai.configured() {
		now := time.now()
		year, month, day := time.date(now)
		hour, minute, second := time.clock(now)
		now_iso := fmt.tprintf("{}-{:02}-{:02}T{:02}:{:02}:{:02}", year, int(month), day, hour, minute, second)
		parsed, ok := ai.parse_todo(title, now_iso)
		if ok && len(parsed.title) > 0 {
			parsed_title = parsed.title
			parsed_remind = parsed.remind_at
		}
	}

	todo_id, err := store.create_todo(store.DB, user_id, parsed_title)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to create todo")
		return
	}

	if remind_iso, has_reminder := parsed_remind.?; has_reminder {
		if remind_unix, ok := store.parse_iso_to_unix(remind_iso); ok {
			store.create_reminder(store.DB, todo_id, user_id, remind_unix)
		}
	}

	row, found := store.get_todo(store.DB, user_id, todo_id)
	if !found {
		_mcp_error(res, id, -32603, "created todo not found")
		return
	}

	_mcp_tool_result(res, id, API_Todo{id = row.id, title = row.title, completed = row.completed})
}

_mcp_tool_update_todo :: proc(res: ^web.Response, id: json.Value, user_id: i64, args: map[string]json.Value) {
	id_val, ok := args["id"]
	if !ok {
		_mcp_error(res, id, -32602, "missing 'id' argument")
		return
	}
	todo_id, idok := _json_to_i64(id_val)
	if !idok {
		_mcp_error(res, id, -32602, "invalid id")
		return
	}

	row, found := store.get_todo(store.DB, user_id, todo_id)
	if !found {
		_mcp_error(res, id, -32602, "todo not found")
		return
	}

	title := row.title
	has_title := false
	if tv, ok := args["title"]; ok {
		if ts, tok := tv.(string); tok {
			title = ts
			has_title = true
		}
	}

	completed := row.completed
	if cv, ok := args["completed"]; ok {
		if cb, cok := cv.(bool); cok {
			completed = cb
		}
	}

	err := store.update_todo(store.DB, user_id, todo_id, title, has_title, completed)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to update todo")
		return
	}

	row, _ = store.get_todo(store.DB, user_id, todo_id)
	_mcp_tool_result(res, id, API_Todo{id = row.id, title = row.title, completed = row.completed})
}

_mcp_tool_delete_todo :: proc(res: ^web.Response, id: json.Value, user_id: i64, args: map[string]json.Value) {
	id_val, ok := args["id"]
	if !ok {
		_mcp_error(res, id, -32602, "missing 'id' argument")
		return
	}
	todo_id, idok := _json_to_i64(id_val)
	if !idok {
		_mcp_error(res, id, -32602, "invalid id")
		return
	}

	deleted := store.delete_todo(store.DB, user_id, todo_id)
	if !deleted {
		_mcp_error(res, id, -32602, "todo not found")
		return
	}

	_mcp_tool_result(res, id, MCP_Status{status = "deleted"})
}

_mcp_tool_get_counts :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	total, active, completed := store.todo_counts(store.DB, user_id)
	_mcp_tool_result(res, id, API_Counts{total = total, active = active, completed = completed})
}

_mcp_tool_toggle_all :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	all_done := store.all_todos_completed(store.DB, user_id)
	store.set_all_completed(store.DB, user_id, !all_done)
	total, active, completed := store.todo_counts(store.DB, user_id)
	_mcp_tool_result(res, id, API_Counts{total = total, active = active, completed = completed})
}

_mcp_tool_clear_completed :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	store.delete_completed_todos(store.DB, user_id)
	total, active, completed := store.todo_counts(store.DB, user_id)
	_mcp_tool_result(res, id, API_Counts{total = total, active = active, completed = completed})
}

_mcp_tool_list_reminders :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	reminders, err := store.list_upcoming_reminders(store.DB, user_id)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to list reminders")
		return
	}

	items := make([]MCP_Reminder_Item, len(reminders), context.temp_allocator)
	for r, i in reminders {
		items[i] = MCP_Reminder_Item{
			reminder_id = r.reminder_id,
			todo_id = r.todo_id,
			title = r.title,
			remind_at = r.remind_at,
		}
	}
	_mcp_tool_result(res, id, items)
}

_mcp_tool_get_web_login_link :: proc(res: ^web.Response, id: json.Value, user_id: i64) {
	token := store.generate_login_token(user_id)
	public_url := os.lookup_env_alloc("PUBLIC_URL", context.temp_allocator) or_else "https://todo.vajraodin.ai"
	login_url := fmt.tprintf("{}/login?token={}", public_url, token)

	_mcp_tool_result(res, id, MCP_Web_Link{url = login_url})
}

_mcp_tool_share_reminder :: proc(res: ^web.Response, id: json.Value, user_id: i64, args: map[string]json.Value) {
	todo_id_val, ok := args["todo_id"]
	if !ok {
		_mcp_error(res, id, -32602, "missing 'todo_id'")
		return
	}
	todo_id, idok := _json_to_i64(todo_id_val)
	if !idok {
		_mcp_error(res, id, -32602, "invalid todo_id")
		return
	}

	bark_val, bok := args["bark_url"]
	if !bok {
		_mcp_error(res, id, -32602, "missing 'bark_url'")
		return
	}
	bark_url, buk := bark_val.(string)
	if !buk || len(bark_url) == 0 {
		_mcp_error(res, id, -32602, "invalid bark_url")
		return
	}

	label := ""
	if lv, lok := args["label"]; lok {
		if ls, lsok := lv.(string); lsok {
			label = ls
		}
	}

	// Find the reminder for this todo.
	reminder_id, found := store.find_reminder_by_todo(store.DB, user_id, todo_id)
	if !found {
		_mcp_error(res, id, -32602, fmt.tprintf("no active reminder for todo {}", todo_id))
		return
	}

	err := store.add_reminder_recipient(store.DB, reminder_id, bark_url, label)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to add recipient")
		return
	}

	_mcp_tool_result(res, id, MCP_Share_Result{status = "ok", todo_id = todo_id, bark_url = bark_url, label = label})
}

// MCP helper types
MCP_Status :: struct {
	status: string `json:"status"`,
}

MCP_Reminder_Item :: struct {
	reminder_id: i64   `json:"reminder_id"`,
	todo_id:     i64   `json:"todo_id"`,
	title:       string `json:"title"`,
	remind_at:   i64   `json:"remind_at"`,
}

MCP_Web_Link :: struct {
	url: string `json:"login_url"`,
}

MCP_Share_Result :: struct {
	status:   string `json:"status"`,
	todo_id:  i64    `json:"todo_id"`,
	bark_url: string `json:"bark_url"`,
	label:    string `json:"label"`,
}

// === MCP response helpers ===

_mcp_result :: proc(res: ^web.Response, id: json.Value, result_json: string) {
	body := fmt.tprintf(`{{"jsonrpc":"2.0","id":{},"result":{}}}`, _json_value_to_string(id), result_json)
	web.respond(res, web.S_200_OK)
	web.set_content_type(res, .Json)
	web.write_string(res, body)
}

_mcp_error :: proc(res: ^web.Response, id: json.Value, code: int, message: string) {
	body := fmt.tprintf(
		`{{"jsonrpc":"2.0","id":{},"error":{{"code":{},"message":{}}}}}`,
		_json_value_to_string(id),
		code,
		_json_quote(message),
	)
	web.respond(res, web.S_200_OK)  // MCP errors use 200, not HTTP error codes
	web.set_content_type(res, .Json)
	web.write_string(res, body)
}

// _mcp_tool_result wraps a value as a tool call result.
_mcp_tool_result :: proc(res: ^web.Response, id: json.Value, v: any) {
	result_bytes, err := json.marshal(v, allocator = context.temp_allocator)
	if err != nil {
		_mcp_error(res, id, -32603, "failed to marshal result")
		return
	}

	// Tool results are wrapped in {content: [{type: "text", text: "..."}]}
	text := string(result_bytes)
	content := fmt.tprintf(
		`{{"content":[{{"type":"text","text":{}}}]}}`,
		_json_quote(text),
	)
	_mcp_result(res, id, content)
}

_json_value_to_string :: proc(v: json.Value) -> string {
	bytes, _ := json.marshal(v, allocator = context.temp_allocator)
	return string(bytes)
}

_json_quote :: proc(s: string) -> string {
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

_json_to_i64 :: proc(v: json.Value) -> (i64, bool) {
	#partial switch val in v {
	case json.Integer: return val, true
	case json.Float:   return i64(val), true
	case:              return 0, false
	}
}
