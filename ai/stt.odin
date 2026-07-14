package ai

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// STT_Response is the response from the OpenAI-compatible Whisper API.
STT_Response :: struct {
	text: string `json:"text"`,
}

// STT provider: "gemini" (default) or "openai"
STT_PROVIDER: string

init_stt_config :: proc() {
	STT_PROVIDER = os.lookup_env_alloc("STT_PROVIDER", context.allocator) or_else "gemini"
	if STT_PROVIDER == "gemini" {
		if k, ok := os.lookup_env_alloc("GEMINI_API_KEY", context.allocator); ok && len(k) > 0 {
			log.info("STT: Gemini (using GEMINI_API_KEY)")
		} else {
			log.warn("STT: Gemini selected but GEMINI_API_KEY not set")
		}
	}
}

// transcribe_audio routes to the configured STT provider.
transcribe_audio :: proc(file_path: string) -> (string, bool) {
	if STT_PROVIDER == "openai" {
		return transcribe_openai(file_path)
	}
	return transcribe_gemini(file_path)
}

// transcribe_gemini uses Google Gemini API to transcribe audio.
// Works with .ogg files directly (TG voice format). No ffmpeg needed.
transcribe_gemini :: proc(file_path: string) -> (string, bool) {
	gemini_key := os.lookup_env_alloc("GEMINI_API_KEY", context.temp_allocator) or_else ""
	if len(gemini_key) == 0 {
		log.error("STT: GEMINI_API_KEY not set")
		return "", false
	}

	// Read and base64 encode the audio file.
	audio_data, err := os.read_entire_file_from_path(file_path, context.temp_allocator)
	if err != nil {
		log.errorf("STT: failed to read %s", file_path)
		return "", false
	}
	audio_b64 := base64.encode(audio_data)

	// Build request JSON using builder (avoids fmt.tprintf brace conflicts).
	req_path := "/tmp/stt_req.json"
	{
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, `{"contents":[{"parts":[{"text":"Transcribe this audio. Return ONLY the transcribed text."},{"inline_data":{"mime_type":"audio/ogg","data":"`)
		strings.write_string(&sb, string(audio_b64))
		strings.write_string(&sb, `"}}]}]}`)
		req_json := strings.to_string(sb)

		write_err := os.write_entire_file(req_path, transmute([]byte)req_json)
		if write_err != nil {
			log.error("STT: failed to write request")
			return "", false
		}
	}
	defer os.remove(req_path)

	// Call Gemini API via curl.
	url := "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
	desc := os.Process_Desc{
		command = []string{
			"curl", "-s", "--max-time", "30",
			"-X", "POST",
			"-H", "Content-Type: application/json",
			"-d", fmt.tprintf("@{}", req_path),
			fmt.tprintf("{}?key={}", url, gemini_key),
		},
	}
	state, stdout, _, exec_err := os.process_exec(desc, context.temp_allocator)
	if exec_err != nil || !state.exited || state.exit_code != 0 {
		log.errorf("STT: Gemini API call failed")
		return "", false
	}

	// Parse response: candidates[0].content.parts[0].text
	body := string(stdout)

	// Quick JSON parse: find "text" : "..."
	text_marker := "\"text\""
	idx := strings.index(body, text_marker)
	if idx < 0 {
		log.errorf("STT: no text in Gemini response: %s", body[:min(len(body), 200)])
		return "", false
	}

	// Move past "text" : "
	pos := idx + len(text_marker)
	// Skip to opening quote of value
	for pos < len(body) && body[pos] != '"' {
		pos += 1
	}
	pos += 1  // skip opening quote
	if pos >= len(body) {
		return "", false
	}

	// Read until closing quote (handle escapes)
	start := pos
	for pos < len(body) {
		if body[pos] == '\\' {
			pos += 2  // skip escaped char
			continue
		}
		if body[pos] == '"' {
			break
		}
		pos += 1
	}

	if pos <= start {
		return "", false
	}

	text := body[start:pos]
	// Unescape
	text, _ = strings.replace(text, "\\n", "\n", -1)
	text, _ = strings.replace(text, "\\\"", "\"", -1)
	text, _ = strings.replace(text, "\\\\", "\\", -1)

	text = strings.trim_space(text)
	if len(text) == 0 {
		return "", false
	}
	return text, true
}

// transcribe_openai uses an OpenAI-compatible /audio/transcriptions endpoint.
transcribe_openai :: proc(file_path: string) -> (string, bool) {
	stt_base := os.lookup_env_alloc("STT_BASE_URL", context.temp_allocator) or_else BASE_URL
	stt_key := os.lookup_env_alloc("STT_API_KEY", context.temp_allocator) or_else API_KEY
	stt_model := os.lookup_env_alloc("AI_STT_MODEL", context.temp_allocator) or_else STT_MODEL

	url := fmt.tprintf("{}/audio/transcriptions", stt_base)
	file_arg := fmt.tprintf("file=@{}", file_path)
	auth := fmt.tprintf("Authorization: Bearer {}", stt_key)

	desc := os.Process_Desc{
		command = []string{
			"curl", "-s", "--max-time", "30",
			"-X", "POST",
			"-H", auth,
			"-F", file_arg,
			"-F", fmt.tprintf("model={}", stt_model),
			url,
		},
	}
	state, stdout, _, err := os.process_exec(desc, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		log.errorf("STT: curl failed for %s", file_path)
		return "", false
	}

	resp: STT_Response
	if err := json.unmarshal_string(string(stdout), &resp); err != nil {
		log.errorf("STT: parse failed: %v", err)
		return "", false
	}

	if len(resp.text) == 0 {
		return "", false
	}
	return resp.text, true
}
