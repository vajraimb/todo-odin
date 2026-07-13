package ai

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"

// STT_Response is the response from the Whisper API.
STT_Response :: struct {
	text: string `json:"text"`,
}

// transcribe_audio sends an audio file to the Whisper API and returns the transcribed text.
// `file_path` is the path to the audio file (e.g. .ogg from Telegram).
// Returns (text, true) on success, ("", false) on failure.
transcribe_audio :: proc(file_path: string) -> (string, bool) {
	if !configured() {
		return "", false
	}

	url := fmt.tprintf("{}/audio/transcriptions", BASE_URL)

	// Build form fields: model=whisper-1
	form_fields := []string{
		fmt.tprintf("model={}", STT_MODEL),
	}

	body, ok := http_upload_file(url, file_path, form_fields)
	if !ok {
		log.errorf("Whisper API request failed for file %s", file_path)
		return "", false
	}

	resp: STT_Response
	if err := json.unmarshal_string(body, &resp); err != nil {
		log.errorf("Whisper response parse failed: %v (body: %s)", err, body[:min(len(body), 200)])
		return "", false
	}

	if len(resp.text) == 0 {
		log.warn("Whisper returned empty text")
		return "", false
	}

	return resp.text, true
}
