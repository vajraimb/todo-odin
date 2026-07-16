#!/usr/bin/env python3
"""STT proxy: OpenAI Whisper format → Gemini audio transcription."""
import sys, json, base64, urllib.request, email.parser, io
from http.server import HTTPServer, BaseHTTPRequestHandler

GEMINI_KEY = sys.argv[1] if len(sys.argv) > 1 else ""
PORT = 9755

def parse_multipart(body, boundary):
    """Extract file content from multipart form data."""
    delim = b"--" + boundary
    parts = body.split(delim)
    for part in parts:
        if b"filename=" in part:
            # Skip headers
            header_end = part.find(b"\r\n\r\n")
            if header_end > 0:
                content = part[header_end+4:]
                # Strip trailing \r\n--
                content = content.rstrip(b"\r\n-")
                return content
    return None

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if not GEMINI_KEY:
            self.send_error(500, "No GEMINI_API_KEY")
            return

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)

        # Parse multipart
        ctype = self.headers.get('Content-Type', '')
        boundary = None
        for part in ctype.split(';'):
            part = part.strip()
            if part.startswith('boundary='):
                boundary = part[9:].strip('"').encode()

        audio_data = None
        if boundary:
            audio_data = parse_multipart(body, boundary)
        if not audio_data:
            self.send_error(400, "No audio file found")
            return

        audio_b64 = base64.b64encode(audio_data).decode()
        req_json = json.dumps({
            "contents": [{"parts": [
                {"text": "Transcribe this audio. Return ONLY the text."},
                {"inline_data": {"mime_type": "audio/ogg", "data": audio_b64}}
            ]}]
        }).encode()

        url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GEMINI_KEY}"
        req = urllib.request.Request(url, data=req_json, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                result = json.loads(resp.read())
            text = result["candidates"][0]["content"]["parts"][0]["text"].strip()
        except Exception as e:
            text = f"Error: {e}"

        out = json.dumps({"text": text}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(out))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):
        pass

print(f"STT proxy on :{PORT}")
HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
