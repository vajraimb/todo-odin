package main

import "core:encoding/base32"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

import "store"
import "web"

// Session is the per-request user context.
// In P1, it just holds the user_id from the DB; the actual todos live in SQLite.
Session :: struct {
	user_id: i64,
}

// Session_Cache caches sessions by cookie id to avoid hitting the DB on every
// request. Entries expire after SESSION_CACHE_TTL. This is optional —
// session_get falls through to DB lookup on cache miss.
Session_Cache_Entry :: struct {
	session:  Session,
	expires:  i64,  // unix timestamp
}

Session_Cache :: struct {
	entries: map[string]Session_Cache_Entry,
	mu:      sync.RW_Mutex,
}

@(private = "file")
session_cache: Session_Cache

SESSION_CACHE_TTL :: 60  // seconds; short since we're a low-traffic app

// session_middleware ensures every request has a valid session.
// - /health is allowed without a session.
// - If the cookie is present and valid, the session is loaded.
// - If not, a new anonymous user + session is created, cookie set, and the
//   browser is redirected to "/" so it re-issues with the cookie.
session_middleware :: proc(req: ^web.Request, res: ^web.Response, next: web.Handler) {
	if req.path == "/health" {
		next(req, res)
		return
	}

	session, ok := session_get(req)
	if ok {
		req.user_ptr = session
		next(req, res)
		return
	}

	// For API routes without a session, let the handler return 401
	// (it will check for a Bearer token, then 401 if none).
	if strings.has_prefix(req.path, "/api/") || strings.has_prefix(req.path, "/mcp") {
		next(req, res)
		return
	}

	// For passkey login routes, no session needed.
	if strings.has_prefix(req.path, "/passkey/login") {
		next(req, res)
		return
	}

	// For web routes: create a session and serve the page directly (no redirect).
	// This avoids cookie-loss issues with reverse proxies like Cloudflare Tunnel.
	// Inherit TG chat_id and webhook from env vars or existing user, so web-created
	// todos also get reminders pushed to the same devices.
	user_id, err := _create_user_with_inherited_settings()
	if err != nil {
		log.errorf("failed to create user: %v", err)
		web.respond_text(res, web.S_500_INTERNAL_SERVER_ERROR, "internal error")
		return
	}

	// Generate a random session id.
	id: [16]byte
	n := rand.read(id[:])
	assert(n == 16)
	sid := base32.encode(id[:])

	err = store.create_session(store.DB, string(sid), user_id)
	if err != nil {
		log.errorf("failed to create session: %v", err)
		web.respond_text(res, web.S_500_INTERNAL_SERVER_ERROR, "internal error")
		return
	}

	web.set_cookie(res, web.Cookie{
		name = "session",
		value = string(sid),
		path = "/",
		same_site = .Lax,
	})

	// Cache it and attach to the request, then continue to the handler.
	s := Session{user_id = user_id}
	_cache_put(string(sid), s)
	session_ptr := new(Session, context.temp_allocator)
	session_ptr^ = s
	req.user_ptr = session_ptr
	next(req, res)
}

// session_get retrieves the session from the request's cookie.
// Checks the in-process cache first, then falls back to the DB.
// Returns (session_ptr, true) on success, (nil, false) if no valid session.
// The returned pointer is allocated on the temp allocator (valid for one request).
session_get :: proc(req: ^web.Request) -> (^Session, bool) {
	cookie, ok := web.cookies_get(req, "session")
	if !ok do return nil, false

	// Cache lookup.
	if s, ok := _cache_get(cookie); ok {
		ptr := new(Session, context.temp_allocator)
		ptr^ = s
		return ptr, true
	}

	// DB lookup.
	result, found := store.session_lookup(store.DB, cookie)
	if !found do return nil, false

	s := Session{user_id = result.user_id}
	_cache_put(cookie, s)
	ptr := new(Session, context.temp_allocator)
	ptr^ = s
	return ptr, true
}

// === Cache helpers ===

_cache_get :: proc(key: string) -> (Session, bool) {
	guard := sync.shared_guard(&session_cache.mu)
	entry, ok := session_cache.entries[key]
	if !ok do return {}, false

	// Check expiry using a rough time source (avoids time.now() per call).
	if _now_unix() > entry.expires {
		return {}, false
	}
	return entry.session, true
}

_cache_put :: proc(key: string, session: Session) {
	guard := sync.guard(&session_cache.mu)
	session_cache.entries[key] = Session_Cache_Entry{
		session = session,
		expires = _now_unix() + SESSION_CACHE_TTL,
	}
}

_now_unix :: proc() -> i64 {
	return store.now_unix()
}

// === Helpers used by handlers ===

// _create_user_with_inherited_settings creates a new user, and if DEFAULT_TG_CHAT_ID
// and DEFAULT_WEBHOOK_URL env vars are set, copies them so web-created todos also
// get TG + Bark push notifications.
_create_user_with_inherited_settings :: proc() -> (i64, store.DB_Error) {
	uid, err := store.create_user(store.DB, "")
	if err != nil do return 0, err

	// Try env vars first. Only set webhook for anonymous web users
	// (tg_chat_id has a unique constraint — can't share Michael's).
	webhook := os.lookup_env_alloc("DEFAULT_WEBHOOK_URL", context.allocator) or_else ""
	if len(webhook) > 0 {
		store.set_user_webhook(store.DB, uid, webhook)
	}

	return uid, nil
}

// session_of_req extracts the Session from the request (set by session_middleware).
// Returns nil if no session is attached (shouldn't happen for non-/health routes).
session_of_req :: proc(req: ^web.Request) -> ^Session {
	if req.user_ptr == nil do return nil
	return cast(^Session)req.user_ptr
}
