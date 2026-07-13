package web

import "core:net"

// HTTP method enum.
Method :: enum {
	Get,
	Post,
	Put,
	Patch,
	Delete,
	Head,
	Options,
	Connect,
	Trace,
	Unknown,
}

method_string :: proc(m: Method) -> string {
	#partial switch m {
	case .Get:     return "GET"
	case .Post:    return "POST"
	case .Put:     return "PUT"
	case .Patch:   return "PATCH"
	case .Delete:  return "DELETE"
	case .Head:    return "HEAD"
	case .Options: return "OPTIONS"
	case .Connect: return "CONNECT"
	case .Trace:   return "TRACE"
	case:          return "UNKNOWN"
	}
}

method_parse :: proc(s: string) -> Method {
	switch s {
	case "GET":     return .Get
	case "POST":    return .Post
	case "PUT":     return .Put
	case "PATCH":   return .Patch
	case "DELETE":  return .Delete
	case "HEAD":    return .Head
	case "OPTIONS": return .Options
	case "CONNECT": return .Connect
	case "TRACE":   return .Trace
	case:           return .Unknown
	}
}

// HTTP status code as a distinct type so we get type safety.
Status :: distinct u16

// Common status codes (a small subset, extend as needed).
S_200_OK :: Status(200)
S_201_CREATED :: Status(201)
S_204_NO_CONTENT :: Status(204)
S_301_MOVED_PERMANENTLY :: Status(301)
S_302_FOUND :: Status(302)
S_304_NOT_MODIFIED :: Status(304)
S_400_BAD_REQUEST :: Status(400)
S_401_UNAUTHORIZED :: Status(401)
S_403_FORBIDDEN :: Status(403)
S_404_NOT_FOUND :: Status(404)
S_405_METHOD_NOT_ALLOWED :: Status(405)
S_409_CONFLICT :: Status(409)
S_413_PAYLOAD_TOO_LARGE :: Status(413)
S_422_UNPROCESSABLE_CONTENT :: Status(422)
S_429_TOO_MANY_REQUESTS :: Status(429)
S_500_INTERNAL_SERVER_ERROR :: Status(500)

status_text :: proc(s: Status) -> string {
	switch u16(s) {
	case 200: return "OK"
	case 201: return "Created"
	case 204: return "No Content"
	case 301: return "Moved Permanently"
	case 302: return "Found"
	case 304: return "Not Modified"
	case 400: return "Bad Request"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 409: return "Conflict"
	case 413: return "Payload Too Large"
	case 422: return "Unprocessable Content"
	case 429: return "Too Many Requests"
	case 500: return "Internal Server Error"
	case:     return "Unknown"
	}
}

// MIME types we care about (extend as needed).
enum_Mime :: enum {
	Html,
	Css,
	Js,
	Json,
	Plain,
	Octet_Stream,
	Ico,
	Png,
	Jpg,
	Svg,
	Wasm,
}

mime_to_content_type :: proc(m: enum_Mime) -> string {
	switch m {
	case .Html:         return "text/html; charset=utf-8"
	case .Css:          return "text/css; charset=utf-8"
	case .Js:           return "application/javascript; charset=utf-8"
	case .Json:         return "application/json; charset=utf-8"
	case .Plain:        return "text/plain; charset=utf-8"
	case .Octet_Stream: return "application/octet-stream"
	case .Ico:          return "image/x-icon"
	case .Png:          return "image/png"
	case .Jpg:          return "image/jpeg"
	case .Svg:          return "image/svg+xml"
	case .Wasm:         return "application/wasm"
	case:               return "application/octet-stream"
	}
}

mime_from_extension :: proc(name: string) -> enum_Mime {
	// Find last dot.
	dot := -1
	for c, i in transmute([]u8)name {
		if c == '.' do dot = i
	}
	if dot < 0 do return .Octet_Stream
	ext := lower(name[dot+1:])
	switch ext {
	case "html", "htm": return .Html
	case "css":         return .Css
	case "js":          return .Js
	case "json":        return .Json
	case "txt":         return .Plain
	case "ico":         return .Ico
	case "png":         return .Png
	case "jpg", "jpeg": return .Jpg
	case "svg":         return .Svg
	case "wasm":        return .Wasm
	case:               return .Octet_Stream
	}
}

lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for c, i in transmute([]u8)s {
		out[i] = u8(unicode_to_lower(rune(c)))
	}
	return transmute(string)(out)
}

unicode_to_lower :: proc(r: rune) -> rune {
	if r >= 'A' && r <= 'Z' do return r + 32
	return r
}

// Header is a name/value pair. Stored as a slice, not a map, because:
// 1) Headers can repeat (Set-Cookie, etc.)
// 2) Order matters for some clients
// 3) Lookups are infrequent compared to parsing overhead
Header :: struct {
	name:  string,
	value: string,
}

Cookie :: struct {
	name:         string,
	value:        string,
	path:         string,
	domain:       string,
	expires_gmt:  Maybe(string),
	max_age_secs: Maybe(i64),
	http_only:    bool,
	secure:       bool,
	same_site:    enum { None, Lax, Strict },
}

// Request represents an inbound HTTP request.
Request :: struct {
	method:     Method,
	raw_method: string,
	raw_url:    string,
	path:       string,
	query:      string,
	headers:    [dynamic]Header,
	body:       []u8,
	url_params: [dynamic]string,
	cookies:    [dynamic]Cookie,
	remote:     net.Endpoint,

	// user_ptr is a slot for middleware/handlers to stash a pointer.
	user_ptr: rawptr,

	// _mw_idx is internal: the current middleware index in the dispatch chain.
	_mw_idx: int,
}

// Response represents an outbound HTTP response being built.
Response :: struct {
	status:  Status,
	headers: [dynamic]Header,
	body:    [dynamic]u8,
	cookies: [dynamic]Cookie,

	// handled lets middleware short-circuit and signal that a response
	// has been written (e.g. redirect from auth middleware).
	handled: bool,
}

// Handler is the basic request handler proc signature.
// Note: Odin proc literals do NOT capture outer variables, so any state
// needed by a handler must be passed through the Request (e.g. user_ptr)
// or stored in a package-level variable.
Handler :: #type proc(req: ^Request, res: ^Response)

// Middleware takes a request, response, and a `next` handler.
// Call `next(req, res)` to continue the chain. Not calling it short-circuits
// (the middleware must write a response in that case).
Middleware :: #type proc(req: ^Request, res: ^Response, next: Handler)
