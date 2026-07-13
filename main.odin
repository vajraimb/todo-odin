package main

import "core:log"
import "core:os"
import "core:strings"
import "core:time"

import "ai"
import "scheduler"
import "store"
import "tg"
import "web"

INDEX: string

init_index :: proc() {
	if s, ok := os.lookup_env_alloc("INDEX", context.allocator); ok {
		INDEX = strings.clone(s)
	} else {
		INDEX = "http://localhost:8080"
	}
}

main :: proc() {
	context.logger = log.create_console_logger(
		.Info,
		log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color, .Thread_Id},
	)

	init_index()

	if err := store.init_db(); err != nil {
		log.errorf("database init failed: %v", err)
		return
	}

	ai.init_config()

	server: web.Server
	web.server_init(&server)
	defer web.server_destroy(&server)

	_register_routes(&server)

	web.use(&server, session_middleware)

	// Start the Telegram bot (if token is configured).
	tg.start_bot()

	// Start the reminder scheduler.
	scheduler.start_reminders()

	port := 8080
	if s, ok := os.lookup_env_alloc("PORT", context.temp_allocator); ok {
		if n, ok := web.parse_int(s); ok {
			port = n
		}
	}

	log.infof("listening on http://0.0.0.0:{}", port)
	web.listen_and_serve(&server, port)

	for { time.sleep(time.Second) }
}

// _register_routes sets up all web and API routes.
_register_routes :: proc(server: ^web.Server) {
	r := &server.router

	// === Health ===
	web.route_get(r, "/health", proc(req: ^web.Request, res: ^web.Response) {
		web.respond(res, web.S_200_OK)
	})

	// === Web (HTMX) routes ===
	web.route_get(r,    "/",                handler_index)
	web.route_get(r,    "/active",          handler_index)
	web.route_get(r,    "/completed",       handler_index)
	web.route_delete(r, "/todos/completed", handler_clean)
	web.route_post(r,   "/todos/toggle",    handler_toggle)
	web.route_post(r,   "/todos",           handler_create_todo)
	web.route_patch(r,  "/todos/:id",       handler_todo_patch)
	web.route_delete(r, "/todos/:id",       handler_delete_todo)

	// === API v1 (JSON) ===
	// Note: specific routes (completed, toggle, count) MUST come before :id
	// to avoid the :id pattern capturing "completed"/"toggle"/"count".
	web.route_get(r,    "/api/v1/todos",           api_list_todos)
	web.route_post(r,   "/api/v1/todos",           api_create_todo)
	web.route_get(r,    "/api/v1/todos/count",     api_counts)
	web.route_post(r,   "/api/v1/todos/toggle",    api_toggle_all)
	web.route_delete(r, "/api/v1/todos/completed", api_clean_completed)
	web.route_patch(r,  "/api/v1/todos/:id",       api_update_todo)
	web.route_delete(r, "/api/v1/todos/:id",       api_delete_todo)

	// API token management
	web.route_post(r,   "/api/v1/tokens",          api_create_token)
	web.route_get(r,    "/api/v1/tokens",          api_list_tokens)
	web.route_delete(r, "/api/v1/tokens/:id",      api_delete_token)

	// Passkey (WebAuthn) registration + login
	web.route_post(r,   "/passkey/register/begin",  passkey_register_begin)
	web.route_post(r,   "/passkey/register/finish", passkey_register_finish)
	web.route_post(r,   "/passkey/login/begin",     passkey_login_begin)
	web.route_post(r,   "/passkey/login/finish",    passkey_login_finish)

	// P6: Agent-friendly endpoints
	web.route_get(r,    "/api/v1/openapi.json",    api_openapi)
	web.route_get(r,    "/api/v1/manifest",        api_manifest)
	web.route_post(r,   "/mcp",                    mcp_handle)

	// Settings page
	web.route_get(r,    "/settings",               handler_settings)
	web.route_post(r,   "/settings/webhook",       handler_save_webhook)

	// Web login via TG magic link
	web.route_get(r,    "/login",                  handler_web_login)

	// === Static files (embedded via #load) ===
	STATIC_CACHE_CONTROL :: "public, max-age=604800"

	web.route_get(r, "/favicon.ico", proc(req: ^web.Request, res: ^web.Response) {
		web.set_header(res, "cache-control", STATIC_CACHE_CONTROL)
		web.respond_file(res, "favicon.ico", #load("static/favicon.ico"))
	})
	web.route_get(r, "/htmx@1.9.5.min.js", proc(req: ^web.Request, res: ^web.Response) {
		web.set_header(res, "cache-control", STATIC_CACHE_CONTROL)
		web.respond_file(res, "htmx@1.9.5.min.js", #load("static/htmx@1.9.5.min.js"))
	})
	web.route_get(r, "/todomvc-app-css@2.4.2-index.css", proc(req: ^web.Request, res: ^web.Response) {
		web.set_header(res, "cache-control", STATIC_CACHE_CONTROL)
		web.respond_file(res, "todomvc-app-css@2.4.2-index.css", #load("static/todomvc-app-css@2.4.2-index.css"))
	})
}
