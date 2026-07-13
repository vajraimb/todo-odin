package ai

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// Parsed_Todo is the result of LLM parsing of natural language input.
Parsed_Todo :: struct {
	title:     string         `json:"title"`,
	remind_at: Maybe(string)  `json:"remind_at"`,  // ISO 8601 or null
}

// Chat completion types
Chat_Message :: struct {
	role:    string `json:"role"`,
	content: string `json:"content"`,
}

Chat_Request :: struct {
	model:           string         `json:"model"`,
	messages:        []Chat_Message `json:"messages"`,
	response_format: Maybe(Response_Format) `json:"response_format"`,
}

Response_Format :: struct {
	type: string `json:"type"`,
}

Chat_Response :: struct {
	choices: []struct {
		message: Chat_Message `json:"message"`,
	} `json:"choices"`,
}

// SYSTEM_PROMPT instructs the LLM to extract structured todo data.
SYSTEM_PROMPT :: `You are a todo list assistant. Parse the user's natural language input and extract:
1. A concise todo title (in the user's language)
2. An optional reminder time in ISO 8601 format (e.g. "2024-01-15T15:00:00")

Rules:
- If the user specifies a time, include "remind_at" in the SAME timezone as the current time below. If no time is mentioned, set "remind_at" to null.
- For relative dates like "tomorrow", "next monday", "tonight", compute the actual date based on the current time provided below.
- "今晚" means today evening. "明天8点" means tomorrow at 8am.
- Keep the title short and actionable. Remove time/date words from the title.
- Respond ONLY with JSON: {"title": "...", "remind_at": "..." or null}

Current time: {current_time}`

// parse_todo uses the LLM to parse natural language into a structured todo.
// Returns (parsed, true) on success, ({}, false) if AI is disabled or parsing fails.
parse_todo :: proc(text: string, current_time_iso: string) -> (Parsed_Todo, bool) {
	if !configured() {
		// Fallback: just use the raw text as the title, no reminder.
		return Parsed_Todo{title = text}, true
	}

	// Build the system prompt with current time.
	system := fmt.tprintf(SYSTEM_PROMPT, current_time_iso)

	// Build the chat request.
	messages := make([]Chat_Message, 2, context.temp_allocator)
	messages[0] = Chat_Message{role = "system", content = system}
	messages[1] = Chat_Message{role = "user", content = text}

	req := Chat_Request{
		model = MODEL,
		messages = messages,
		response_format = Response_Format{type = "json_object"},
	}

	req_bytes, err := json.marshal(req, allocator = context.temp_allocator)
	if err != nil {
		log.errorf("LLM marshal failed: %v", err)
		return Parsed_Todo{title = text}, true  // fallback to raw text
	}

	url := fmt.tprintf("{}/chat/completions", BASE_URL)
	body, ok := http_post_json_auth(url, string(req_bytes))
	if !ok {
		log.warnf("LLM request failed, falling back to raw text")
		return Parsed_Todo{title = text}, true
	}

	// Parse the chat response.
	resp: Chat_Response
	if err := json.unmarshal_string(body, &resp); err != nil {
		log.warnf("LLM response parse failed: %v (body: %s)", err, body[:min(len(body), 200)])
		return Parsed_Todo{title = text}, true
	}

	if len(resp.choices) == 0 {
		log.warn("LLM returned no choices")
		return Parsed_Todo{title = text}, true
	}

	content := resp.choices[0].message.content

	// Parse the JSON content.
	parsed: Parsed_Todo
	if err := json.unmarshal_string(content, &parsed); err != nil {
		log.warnf("LLM content JSON parse failed: %v (content: %s)", err, content[:min(len(content), 200)])
		return Parsed_Todo{title = text}, true
	}

	if len(parsed.title) == 0 {
		parsed.title = text
	}

	return parsed, true
}

min :: proc(a, b: int) -> int {
	if a < b do return a
	return b
}
