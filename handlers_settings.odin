package main

import "core:encoding/base32"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

import "store"
import "tg"
import "web"

// handler_settings renders the settings page with token list, webhook, and passkey status.
handler_settings :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond_redirect(res, web.S_302_FOUND, "/")
		return
	}

	// Fetch tokens.
	tokens, err := store.list_api_tokens(store.DB, session.user_id)
	if err != nil {
		log.errorf("settings: list_api_tokens failed: %v", err)
		tokens = nil
	}

	// Fetch webhook URL.
	webhook_url := store.get_user_webhook(store.DB, session.user_id)

	// Count passkeys.
	passkey_count := _count_passkeys(session.user_id)

	// Check if this user is linked to TG.
	tg_chat := _get_user_tg_chat(session.user_id)

	html := render_settings_page(tokens, webhook_url, passkey_count, tg_chat)
	web.respond_html(res, web.S_200_OK, html)
}

// handler_save_webhook saves the webhook URL from the settings form.
handler_save_webhook :: proc(req: ^web.Request, res: ^web.Response) {
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

	url := body["url"]
	err := store.set_user_webhook(store.DB, session.user_id, url)
	if err != nil {
		log.errorf("save_webhook failed: %v", err)
		web.respond(res, web.S_500_INTERNAL_SERVER_ERROR)
		return
	}

	web.respond_redirect(res, web.S_302_FOUND, "/settings")
}

// handler_web_login handles the /login?token=XXX magic link.
// Creates or relinks a web session to the verified TG user.
handler_web_login :: proc(req: ^web.Request, res: ^web.Response) {
	token, ok := _query_param(req.query, "token")
	if !ok || len(token) == 0 {
		web.respond_text(res, web.S_400_BAD_REQUEST, "Missing login token.")
		return
	}

	user_id, valid := tg.consume_login_token(token)
	if !valid {
		web.respond_text(res, web.S_401_UNAUTHORIZED, "Invalid or expired token. Send /web to get a new link.")
		return
	}

	// If user already has a session cookie, relink it.
	cookie, cok := web.cookies_get(req, "session")
	if cok {
		store.link_session_to_user(store.DB, cookie, user_id)
		_cache_put(cookie, Session{user_id = user_id, session_id = cookie})
		log.infof("web login: relinked session to user {}", user_id)
		web.respond_redirect(res, web.S_302_FOUND, "/")
		return
	}

	// No cookie yet — create a new session for the target user directly.
	id_bytes: [16]byte
	_ = rand.read(id_bytes[:])
	new_sid := string(base32.encode(id_bytes[:]))
	store.create_session(store.DB, new_sid, user_id)

	web.set_cookie(res, web.Cookie{
		name = "session",
		value = new_sid,
		path = "/",
		same_site = .Lax,
	})

	_cache_put(new_sid, Session{user_id = user_id, session_id = new_sid})
	log.infof("web login: created session for user {}", user_id)
	web.respond_redirect(res, web.S_302_FOUND, "/")
}

// _count_passkeys returns the number of passkey credentials for a user.
_count_passkeys :: proc(user_id: i64) -> int {
	stmt, rc := store.prepare(store.DB, "SELECT COUNT(*) FROM passkey_credentials WHERE user_id = ?;")
	if rc != store.OK do return 0
	defer store.finalize_safe(stmt)
	_ = store.bind_int64(stmt, 1, user_id)
	if !store.step_row(stmt) do return 0
	return int(store.column_int64(stmt, 0))
}

// _get_user_tg_chat returns the tg_chat_id for a user (0 if not linked).
_get_user_tg_chat :: proc(user_id: i64) -> i64 {
	stmt, rc := store.prepare(store.DB, "SELECT COALESCE(tg_chat_id, 0) FROM users WHERE id = ?;")
	if rc != store.OK do return 0
	defer store.finalize_safe(stmt)
	_ = store.bind_int64(stmt, 1, user_id)
	if !store.step_row(stmt) do return 0
	return store.column_int64(stmt, 0)
}
