package ai

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// AI API configuration. Set via environment variables.
// Works with OpenAI, DeepSeek (OpenAI-compatible), or local ollama.
API_KEY:   string
BASE_URL:  string  // e.g. "https://api.openai.com/v1"
MODEL:     string  // e.g. "gpt-4o-mini" or "deepseek-chat"
STT_MODEL: string  // e.g. "whisper-1"

// configured returns true if AI is enabled (API key is set).
configured :: proc() -> bool {
	return len(API_KEY) > 0
}

init_config :: proc() {
	if v, ok := os.lookup_env_alloc("AI_API_KEY", context.allocator); ok {
		API_KEY = strings.clone(v)
	}
	if v, ok := os.lookup_env_alloc("AI_BASE_URL", context.allocator); ok {
		BASE_URL = strings.clone(v)
	} else {
		BASE_URL = "https://api.openai.com/v1"
	}
	if v, ok := os.lookup_env_alloc("AI_MODEL", context.allocator); ok {
		MODEL = strings.clone(v)
	} else {
		MODEL = "gpt-4o-mini"
	}
	if v, ok := os.lookup_env_alloc("AI_STT_MODEL", context.allocator); ok {
		STT_MODEL = strings.clone(v)
	} else {
		STT_MODEL = "whisper-1"
	}

	if configured() {
		log.infof("AI enabled: base=%s model=%s stt=%s", BASE_URL, MODEL, STT_MODEL)
	} else {
		log.info("AI disabled (set AI_API_KEY to enable)")
	}
}

// === HTTP helpers (curl-based, same as tg/api.odin) ===

// http_post_json sends a POST with JSON body and Authorization header.
// Returns the response body.
http_post_json_auth :: proc(url: string, json_body: string) -> (string, bool) {
	auth_header := fmt.tprintf("Authorization: Bearer {}", API_KEY)
	state, stdout, _, ok := exec_capture([]string{
		"curl", "-s", "-X", "POST",
		"-H", "Content-Type: application/json",
		"-H", auth_header,
		"-d", json_body,
		url,
	})
	if !ok || !state.exited || state.exit_code != 0 {
		return "", false
	}
	return stdout, true
}

// http_download downloads a URL to a file. Returns true on success.
http_download :: proc(url: string, file_path: string) -> bool {
	state, _, _, ok := exec_capture([]string{"curl", "-s", "-o", file_path, url})
	if !ok || !state.exited || state.exit_code != 0 {
		return false
	}
	return true
}

// http_upload_file uploads a file via multipart form POST.
// `form_fields` is a list of "key=value" strings for additional form fields.
http_upload_file :: proc(url: string, file_path: string, form_fields: []string) -> (string, bool) {
	args := make([dynamic]string, 0, 8 + len(form_fields), context.temp_allocator)
	defer delete(args)
	append(&args, "curl")
	append(&args, "-s")
	append(&args, "-X")
	append(&args, "POST")
	append(&args, "-H")
	append(&args, fmt.tprintf("Authorization: Bearer {}", API_KEY))
	file_arg := fmt.tprintf("file=@{}", file_path)
	append(&args, "-F")
	append(&args, file_arg)
	for field in form_fields {
		append(&args, "-F")
		append(&args, field)
	}
	append(&args, url)

	state, stdout, _, ok := exec_capture(args[:])
	if !ok || !state.exited || state.exit_code != 0 {
		return "", false
	}
	return stdout, true
}

// json_escape_string escapes a string for JSON value inclusion.
json_escape_string :: proc(s: string) -> string {
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
