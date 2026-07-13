package web

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// === Header helpers ===

// headers_get returns the first value for the given header name (case-insensitive).
// Returns (value, true) if found, ("", false) otherwise.
headers_get :: proc(headers: []Header, name: string) -> (string, bool) {
	lname := lower(name, context.temp_allocator)
	for h in headers {
		if lower(h.name, context.temp_allocator) == lname {
			return h.value, true
		}
	}
	return "", false
}

headers_has :: proc(headers: []Header, name: string) -> bool {
	_, ok := headers_get(headers, name)
	return ok
}

// headers_set replaces any existing header with this name, or appends if not present.
headers_set :: proc(headers: ^[dynamic]Header, name: string, value: string) {
	lname := lower(name, context.temp_allocator)
	for i in 0..<len(headers) {
		if lower(headers[i].name, context.temp_allocator) == lname {
			headers[i].value = value
			return
		}
	}
	append(headers, Header{name = name, value = value})
}

// headers_add appends a header without replacing existing ones (for Set-Cookie etc).
headers_add :: proc(headers: ^[dynamic]Header, name: string, value: string) {
	append(headers, Header{name = name, value = value})
}

set_header :: proc(res: ^Response, name: string, value: string) {
	headers_set(&res.headers, name, value)
}

set_content_type :: proc(res: ^Response, mime: enum_Mime) {
	headers_set(&res.headers, "content-type", mime_to_content_type(mime))
}

// === Cookie helpers ===

cookies_get :: proc(req: ^Request, name: string) -> (string, bool) {
	for c in req.cookies {
		if c.name == name {
			return c.value, true
		}
	}
	return "", false
}

set_cookie :: proc(res: ^Response, c: Cookie) {
	append(&res.cookies, c)
}

// === Response helpers ===

respond :: proc(res: ^Response, status: Status) {
	res.status = status
	res.handled = true
}

respond_text :: proc(res: ^Response, status: Status, body: string) {
	res.status = status
	set_content_type(res, .Plain)
	append(&res.body, body)
	res.handled = true
}

respond_html :: proc(res: ^Response, status: Status, body: string) {
	res.status = status
	set_content_type(res, .Html)
	append(&res.body, body)
	res.handled = true
}

respond_json :: proc(res: ^Response, status: Status, v: $T) -> ! {
	res.status = status
	set_content_type(res, .Json)
	buf, err := json.marshal(v, context.temp_allocator)
	if err != nil {
		return err
	}
	append(&res.body, ..buf)
	res.handled = true
	return nil
}

respond_redirect :: proc(res: ^Response, status: Status, location: string) {
	res.status = status
	headers_set(&res.headers, "location", location)
	res.handled = true
}

// respond_file responds with file bytes embedded at compile time via #load.
// `filename` is used only to derive a content-type.
respond_file :: proc(res: ^Response, filename: string, data: []u8) {
	res.status = S_200_OK
	mime := mime_from_extension(filename)
	set_content_type(res, mime)
	append(&res.body, ..data)
	res.handled = true
}

// write_string appends a string to the response body (for template rendering).
write_string :: proc(res: ^Response, s: string) {
	append(&res.body, s)
}

// write_bytes appends raw bytes to the response body.
write_bytes :: proc(res: ^Response, b: []u8) {
	append(&res.body, ..b)
}

// write_fmt appends a formatted string to the response body.
write_fmt :: proc(res: ^Response, fmt_string: string, args: ..any) {
	s := fmt.tprintf(fmt_string, ..args)
	append(&res.body, s)
}

// === Body parsing ===

// parse_url_encoded parses an application/x-www-form-urlencoded body
// into a temp-allocated map[string]string.
parse_url_encoded :: proc(body: []u8) -> (map[string]string, bool) {
	if len(body) == 0 do return {}, false
	out: map[string]string
	out = make(map[string]string, context.temp_allocator)

	// Split by '&' or ';'.
	start: int = 0
	for c, i in body {
		if c == '&' || c == ';' {
			_pair(body[start:i], &out)
			start = i + 1
		}
	}
	_pair(body[start:], &out)
	return out, true
}

_pair :: proc(pair: []u8, out: ^map[string]string) {
	if len(pair) == 0 do return
	eq := -1
	for c, i in pair {
		if c == '=' {
			eq = i
			break
		}
	}
	if eq < 0 {
		// No '=', treat as key with empty value.
		key := url_decode(transmute(string)(pair), context.temp_allocator)
		out[key] = ""
		return
	}
	key := url_decode(transmute(string)(pair[:eq]), context.temp_allocator)
	val := url_decode(transmute(string)(pair[eq+1:]), context.temp_allocator)
	out[key] = val
}

// url_decode decodes %XX escapes and '+' -> ' '. Returns a new string.
url_decode :: proc(s: string, allocator := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(s), allocator)
	i: int = 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '+':
			append(&out, ' ')
			i += 1
		case c == '%' && i+2 < len(s):
			h1 := hex_digit(s[i+1])
			h2 := hex_digit(s[i+2])
			if h1 >= 0 && h2 >= 0 {
				append(&out, u8(h1*16 + h2))
			} else {
				append(&out, c)
			}
			i += 3
		case:
			append(&out, c)
			i += 1
		}
	}
	result := transmute(string)(out[:])
	// Note: we intentionally leak the dynamic container's header;
	// the returned string slice is valid as long as the allocator is.
	return result
}

hex_digit :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	case:                       return -1
	}
}

// url_encode encodes a string for use in a URL (query value or path segment).
url_encode :: proc(s: string, allocator := context.allocator) -> string {
	out := make([dynamic]u8, 0, len(s), allocator)
	for c in transmute([]u8)s {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			append(&out, c)
		case c == '-' || c == '_' || c == '.' || c == '~':
			append(&out, c)
		case:
			append(&out, '%')
			append(&out, hex_byte(c, 1))
			append(&out, hex_byte(c, 0))
		}
	}
	return transmute(string)(out[:])
}

hex_byte :: proc(b: u8, idx: int) -> u8 {
	// idx 0 = low nibble, idx 1 = high nibble.
	shift: u32 = u32(4 * (1 - idx))
	nibble := (b >> shift) & 0x0F
	if nibble < 10 do return '0' + nibble
	return 'a' + nibble - 10
}

// === Cookie header parsing ===

// parse_cookie_header parses "Cookie: a=b; c=d" into Cookie structs.
parse_cookie_header :: proc(req: ^Request, header_value: string) {
	// Pairs separated by ';' (and optional whitespace).
	start: int = 0
	s := header_value
	for c, i in transmute([]u8)s {
		if c == ';' {
			_add_cookie(req, strings.trim_space(s[start:i]))
			start = i + 1
		}
	}
	if start < len(s) {
		_add_cookie(req, strings.trim_space(s[start:]))
	}
}

_add_cookie :: proc(req: ^Request, pair: string) {
	if len(pair) == 0 do return
	eq := strings.index_byte(pair, '=')
	if eq < 0 do return
	c := Cookie{
		name = strings.trim_space(pair[:eq]),
		value = strings.trim_space(pair[eq+1:]),
	}
	append(&req.cookies, c)
}

// render_cookie serializes a Cookie into a Set-Cookie header value.
render_cookie :: proc(c: Cookie) -> string {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, fmt.tprintf("{}={}", c.name, c.value))
	if len(c.path) > 0 {
		strings.write_string(&sb, fmt.tprintf("; Path={}", c.path))
	}
	if len(c.domain) > 0 {
		strings.write_string(&sb, fmt.tprintf("; Domain={}", c.domain))
	}
	if exp, ok := c.expires_gmt.?; ok {
		strings.write_string(&sb, fmt.tprintf("; Expires={}", exp))
	}
	if ma, ok := c.max_age_secs.?; ok {
		strings.write_string(&sb, fmt.tprintf("; Max-Age={}", ma))
	}
	if c.http_only {
		strings.write_string(&sb, "; HttpOnly")
	}
	if c.secure {
		strings.write_string(&sb, "; Secure")
	}
	switch c.same_site {
	case .None:   strings.write_string(&sb, "; SameSite=None")
	case .Lax:    strings.write_string(&sb, "; SameSite=Lax")
	case .Strict: strings.write_string(&sb, "; SameSite=Strict")
	}
	return strings.to_string(sb)
}
