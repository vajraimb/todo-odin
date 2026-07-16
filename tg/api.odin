package tg

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import "../ai"

// TG_API_BASE is the Telegram Bot API base URL.
TG_API_BASE :: "https://api.telegram.org/bot"

// Token is the bot token, set from the TG_BOT_TOKEN env var.
Token: string

init_token :: proc() -> bool {
	if t, ok := os.lookup_env_alloc("TG_BOT_TOKEN", context.allocator); ok {
		Token = strings.clone(t)
		return true
	}
	return false
}

// === API types ===

TG_Update :: struct {
	update_id: i64           `json:"update_id"`,
	message:    Maybe(TG_Message) `json:"message"`,
}

TG_Message :: struct {
	message_id: i64          `json:"message_id"`,
	text:       string       `json:"text"`,
	chat:       TG_Chat      `json:"chat"`,
	from:       Maybe(TG_User) `json:"from"`,
	voice:      Maybe(TG_Voice) `json:"voice"`,
}

TG_Voice :: struct {
	file_id:   string `json:"file_id"`,
	duration:  int    `json:"duration"`,
}

TG_Chat :: struct {
	id:     i64    `json:"id"`,
	type:   string `json:"type"`,
	title:  string `json:"title"`,
}

TG_User :: struct {
	id:           i64    `json:"id"`,
	first_name:   string `json:"first_name"`,
	username:     string `json:"username"`,
}

// File response from getFile API.
TG_File :: struct {
	file_id:       string `json:"file_id"`,
	file_path:     string `json:"file_path"`,
	file_size:     int    `json:"file_size"`,
}

TG_File_Response :: struct {
	ok:     bool    `json:"ok"`,
	result: TG_File `json:"result"`,
}

// API response wrapper for getUpdates.
TG_Updates_Response :: struct {
	ok:          bool         `json:"ok"`,
	result:      []TG_Update  `json:"result"`,
	description: string       `json:"description"`,
}

// API response wrapper for sendMessage (just checks ok).
TG_Send_Response :: struct {
	ok:          bool   `json:"ok"`,
	description: string `json:"description"`,
}

// === HTTP client (via curl subprocess) ===

// http_post_json makes an HTTPS POST request with a JSON body and returns the response body.
// Uses curl as a subprocess for TLS support (avoids linking OpenSSL directly).
http_post_json :: proc(url: string, json_body: string) -> (string, bool) {
	state, stdout, _, ok := ai.exec_capture([]string{
		"curl", "-s", "-X", "POST",
		"-H", "Content-Type: application/json",
		"-d", json_body,
		url,
	})
	if !ok {
		return "", false
	}
	if !state.exited || state.exit_code != 0 {
		log.errorf("curl failed (exit_code={})", state.exit_code)
		return "", false
	}
	return stdout, true
}

http_get :: proc(url: string) -> (string, bool) {
	state, stdout, _, ok := ai.exec_capture([]string{"curl", "-s", url})
	if !ok {
		return "", false
	}
	if !state.exited {
		return "", false
	}
	return stdout, true
}

// === Bot API methods ===

// get_updates calls the TG getUpdates long-poll endpoint.
// `offset` is the last update_id + 1; `timeout` is the long-poll seconds.
get_updates :: proc(offset: i64, timeout: int) -> ([]TG_Update, bool) {
	url := fmt.tprintf("{}{}/getUpdates?offset={}&timeout={}", TG_API_BASE, Token, offset, timeout)
	body, ok := http_get(url)
	if !ok do return nil, false

	// Parse the response.
	resp: TG_Updates_Response
	if err := json.unmarshal_string(body, &resp); err != nil {
		log.errorf("get_updates JSON parse failed: %v (body: %s)", err, body[:min(len(body), 200)])
		return nil, false
	}
	if !resp.ok {
		log.errorf("get_updates not ok: %s", resp.description)
		return nil, false
	}
	return resp.result, true
}

// send_message sends a text message to a chat.
send_message :: proc(chat_id: i64, text: string) -> bool {
	json_body := fmt.tprintf(`{{"chat_id":{},"text":{}}}`, chat_id, json_quote_string(text))
	url := fmt.tprintf("{}{}/sendMessage", TG_API_BASE, Token)
	body, ok := http_post_json(url, json_body)
	if !ok do return false

	resp: TG_Send_Response
	if err := json.unmarshal_string(body, &resp); err != nil {
		log.warnf("send_message response parse failed: %v", err)
	}
	return resp.ok
}

// json_quote_string escapes a string for inclusion in a JSON value.
json_quote_string :: proc(s: string) -> string {
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

// get_file calls the TG getFile API to get the file_path for a file_id.
get_file :: proc(file_id: string) -> (string, bool) {
	url := fmt.tprintf("{}{}/getFile?file_id={}", TG_API_BASE, Token, file_id)
	body, ok := http_get(url)
	if !ok do return "", false

	resp: TG_File_Response
	if err := json.unmarshal_string(body, &resp); err != nil {
		log.errorf("get_file JSON parse failed: %v", err)
		return "", false
	}
	if !resp.ok {
		return "", false
	}
	return resp.result.file_path, true
}

// download_file_url returns the full download URL for a TG file_path.
download_file_url :: proc(file_path: string) -> string {
	return fmt.tprintf("https://api.telegram.org/file/bot{}/{}", Token, file_path)
}

min :: proc(a, b: int) -> int {
	if a < b do return a
	return b
}
