package web

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:thread"

// READ_BUFFER_SIZE is the size of the per-connection read buffer.
READ_BUFFER_SIZE :: 8192

// MAX_HEADER_SIZE is the maximum total size of request headers.
MAX_HEADER_SIZE :: 1 << 20 // 1 MiB

// MAX_BODY_SIZE is the default maximum body size (1 MiB).
MAX_BODY_SIZE :: 1 << 20

// Server holds the router and middleware chain.
Server :: struct {
	router:     Router,
	middleware: [dynamic]Middleware,
}

server_init :: proc(s: ^Server) {
	router_init(&s.router)
	s.middleware = make([dynamic]Middleware)
}

server_destroy :: proc(s: ^Server) {
	router_destroy(&s.router)
	delete(s.middleware)
}

// use registers a middleware. Must be called before listen_and_serve.
use :: proc(s: ^Server, m: Middleware) {
	append(&s.middleware, m)
}

// listen_and_serve binds to the given port on all interfaces and starts
// accepting connections. Each connection is handled in its own thread.
// This proc does not return unless there is a fatal error.
listen_and_serve :: proc(s: ^Server, port: int) {
	endpoint := net.Endpoint{
		address = net.IP4_Any,
		port    = port,
	}

	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		log.errorf("listen_tcp failed: %v", err)
		return
	}

	log.infof("listening on http://0.0.0.0:{}", port)

	for {
		client, source, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.errorf("accept failed: %v", accept_err)
			continue
		}

		// Spawn a thread per connection.
		// The thread owns the client socket and frees it when done.
		ctx := new(_Conn_Context)
		ctx.server = s
		ctx.client = client
		ctx.source = source

		thread.run_with_data(ctx, _conn_handler)
	}
}

_Conn_Context :: struct {
	server: ^Server,
	client: net.TCP_Socket,
	source: net.Endpoint,
}

// _conn_handler is the entry point for each connection thread.
_conn_handler :: proc(data: rawptr) {
	ctx := cast(^_Conn_Context)data
	defer {
		net.close(ctx.client)
		free(ctx)
	}

	buf := make([]u8, READ_BUFFER_SIZE)
	defer delete(buf)

	// Read until we have all headers (terminate on \r\n\r\n).
	req_data := _read_until_headers(ctx.client, buf[:])
	if len(req_data) == 0 do return

	req, parse_err := _parse_request(req_data, ctx.source)
	if len(parse_err) > 0 {
		log.warnf("parse failed: %s", parse_err)
		return
	}
	defer _request_destroy(&req)

	// Read body if Content-Length is set.
	if cl, ok := headers_get(req.headers[:], "content-length"); ok {
		claimed, ok := parse_int(cl)
		if ok && claimed > 0 {
			if claimed > MAX_BODY_SIZE {
				_respond_simple(ctx.client, S_413_PAYLOAD_TOO_LARGE, "body too large\n")
				return
			}
			body := _read_body(ctx.client, buf[:], req_data, claimed)
			if body == nil {
				log.warn("failed to read body")
				return
			}
			req.body = body
		}
	}

	// Parse cookies from Cookie header.
	if cookie_val, ok := headers_get(req.headers[:], "cookie"); ok {
		parse_cookie_header(&req, cookie_val)
	}

	// Build response.
	res := _response_new()
	defer _response_destroy(&res)

	// Dispatch through middleware + router.
	dispatch(ctx.server, &req, &res)

	// Write response (always, even if handler didn't set handled).
	_write_response(ctx.client, &req, &res)
}

// _read_until_headers reads from the socket until \r\n\r\n is found.
// Returns the full bytes of headers (without body).
// If connection closes before headers, returns empty slice.
_read_until_headers :: proc(sock: net.TCP_Socket, buf: []u8) -> []u8 {
	accum := make([dynamic]u8, 0, READ_BUFFER_SIZE, context.temp_allocator)

	for {
		n, err := net.recv_tcp(sock, buf)
		if err != nil {
			return {}
		}
		if n == 0 {
			// graceful close
			return {}
		}
		append(&accum, ..buf[:n])

		// Look for \r\n\r\n.
		idx := _find_subslice(accum[:], "\r\n\r\n")
		if idx >= 0 {
			// Return the FULL accumulated buffer, including any body bytes
			// that may have arrived in the same recv. _read_body will
			// extract the pre-read body portion.
			return accum[:]
		}

		if len(accum) > MAX_HEADER_SIZE {
			log.warn("headers too large")
			return {}
		}
	}
}

_find_subslice :: proc(haystack: []u8, needle: string) -> int {
	if len(needle) == 0 do return 0
	if len(haystack) < len(needle) do return -1
	n := transmute([]u8)needle
	for i in 0..=len(haystack)-len(needle) {
		match := true
		for j in 0..<len(needle) {
			if haystack[i+j] != n[j] {
				match = false
				break
			}
		}
		if match do return i
	}
	return -1
}

// _read_body reads exactly `content_length` bytes of body.
// `header_bytes` may already contain some pre-read body bytes (after \r\n\r\n).
_read_body :: proc(sock: net.TCP_Socket, buf: []u8, header_bytes: []u8, content_length: int) -> []u8 {
	body := make([]u8, content_length)

	// Bytes after the header terminator might already contain body data.
	header_end := _find_subslice(header_bytes, "\r\n\r\n")
	pre_read := 0
	if header_end >= 0 {
		pre_read = len(header_bytes) - (header_end + 4)
		if pre_read > content_length do pre_read = content_length
		copy(body, header_bytes[header_end+4:header_end+4+pre_read])
	}

	// Read the rest.
	remaining := content_length - pre_read
	offset := pre_read
	for remaining > 0 {
		n, err := net.recv_tcp(sock, buf)
		if err != nil || n == 0 {
			delete(body)
			return nil
		}
		to_copy := min(n, remaining)
		copy(body[offset:offset+to_copy], buf[:to_copy])
		offset += to_copy
		remaining -= to_copy
	}

	return body
}

parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 do return 0, false
	n: int = 0
	for c in s {
		if c < '0' || c > '9' do return 0, false
		n = n*10 + int(c - '0')
	}
	return n, true
}

// _parse_request parses the HTTP request from `data` (which must contain at least
// up to the \r\n\r\n terminator). Returns (req, "") on success or (req, err_msg) on failure.
_parse_request :: proc(data: []u8, source: net.Endpoint) -> (req: Request, err: string) {
	// Split request line and headers.
	header_end := _find_subslice(data, "\r\n\r\n")
	if header_end < 0 {
		return {}, "no header terminator"
	}

	header_block := data[:header_end]
	// Make a mutable copy allocated on the regular allocator so it survives
	// past the temp allocator's lifetime.
	header_str := strings.clone(transmute(string)(header_block))

	// Split into lines.
	lines := strings.split(header_str, "\r\n")
	if len(lines) == 0 {
		return {}, "empty request"
	}

	// Parse request line: METHOD PATH HTTP/1.1
	req_line := lines[0]
	parts := strings.fields(req_line)
	if len(parts) < 2 {
		return {}, fmt.tprintf("malformed request line: %q", req_line)
	}

	req.raw_method = strings.clone(parts[0])
	req.method = method_parse(req.raw_method)
	req.raw_url = strings.clone(parts[1])

	// Split path and query.
	q := strings.index_byte(req.raw_url, '?')
	if q >= 0 {
		req.path = req.raw_url[:q]
		req.query = req.raw_url[q+1:]
	} else {
		req.path = req.raw_url
		req.query = ""
	}

	// Parse headers (skip first line which is the request line).
	req.headers = make([dynamic]Header, 0, 8)
	for line in lines[1:] {
		if len(line) == 0 do continue
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue
		name := strings.clone(strings.trim_space(line[:colon]))
		value := strings.clone(strings.trim_space(line[colon+1:]))
		append(&req.headers, Header{name = name, value = value})
	}

	req.url_params = make([dynamic]string, 0, 4)
	req.cookies = make([dynamic]Cookie, 0, 2)
	req.remote = source

	return req, ""
}

_request_destroy :: proc(req: ^Request) {
	delete(req.raw_method)
	delete(req.raw_url)
	// path and query are slices of raw_url, freed by raw_url's delete above.
	for h in req.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(req.headers)
	delete(req.url_params)
	delete(req.cookies)
	if req.body != nil && len(req.body) > 0 {
		delete(req.body)
	}
}

_response_new :: proc() -> Response {
	return Response{
		status = S_200_OK,
		headers = make([dynamic]Header, 0, 8),
		body = make([dynamic]u8, 0, 1024),
		cookies = make([dynamic]Cookie, 0, 2),
		handled = false,
	}
}

_response_destroy :: proc(res: ^Response) {
	delete(res.headers)
	delete(res.body)
	delete(res.cookies)
}

// _write_response serializes and sends the response.
_write_response :: proc(sock: net.TCP_Socket, req: ^Request, res: ^Response) {
	if !res.handled {
		// Handler didn't write anything; default to 404.
		res.status = S_404_NOT_FOUND
		set_content_type(res, .Plain)
		append(&res.body, "404 Not Found\n")
	}

	// Build response.
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	// Status line.
	strings.write_string(&sb, fmt.tprintf("HTTP/1.1 {} {}\r\n", u16(res.status), status_text(res.status)))

	// Default headers if not set.
	if !headers_has(res.headers[:], "content-length") {
		strings.write_string(&sb, fmt.tprintf("Content-Length: {}\r\n", len(res.body)))
	}
	if !headers_has(res.headers[:], "connection") {
		// We close after each request for simplicity.
		strings.write_string(&sb, "Connection: close\r\n")
	}

	// Other headers.
	for h in res.headers {
		strings.write_string(&sb, fmt.tprintf("{}: {}\r\n", h.name, h.value))
	}

	// Set-Cookie headers (one per cookie).
	for c in res.cookies {
		strings.write_string(&sb, fmt.tprintf("Set-Cookie: {}\r\n", render_cookie(c)))
	}

	strings.write_string(&sb, "\r\n")

	// Headers.
	header_str := strings.to_string(sb)
	net.send_tcp(sock, transmute([]u8)header_str)

	// Body.
	if len(res.body) > 0 {
		net.send_tcp(sock, res.body[:])
	}
}

_respond_simple :: proc(sock: net.TCP_Socket, status: Status, body: string) {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, fmt.tprintf("HTTP/1.1 {} {}\r\n", u16(status), status_text(status)))
	strings.write_string(&sb, fmt.tprintf("Content-Length: {}\r\n", len(body)))
	strings.write_string(&sb, "Content-Type: text/plain; charset=utf-8\r\n")
	strings.write_string(&sb, "Connection: close\r\n\r\n")
	strings.write_string(&sb, body)
	out := strings.to_string(sb)
	net.send_tcp(sock, transmute([]u8)out)
}
