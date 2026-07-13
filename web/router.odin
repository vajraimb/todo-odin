package web

import "core:fmt"
import "core:log"
import "core:strings"

// Route is a single (method, pattern) -> handler mapping.
Route :: struct {
	method:   Method,
	pattern:  string,
	segments: []string,  // pre-split pattern segments (e.g. ["todos", ":id"])
	handler:  Handler,
}

// Router holds all registered routes.
Router :: struct {
	routes: [dynamic]Route,
}

router_init :: proc(r: ^Router) {
	r.routes = make([dynamic]Route)
}

router_destroy :: proc(r: ^Router) {
	for route in r.routes {
		delete(route.segments)
	}
	delete(r.routes)
}

// route registers a handler for the given method and pattern.
// Pattern syntax:
//   "/"            exact match
//   "/todos"       exact match
//   "/todos/:id"   captures the segment as url_params[0]
//   "/todos/:id/*" wildcard suffix (matches any remaining path)
route :: proc(r: ^Router, method: Method, pattern: string, h: Handler) {
	segments := split_segments(pattern, context.allocator)
	append(&r.routes, Route{
		method = method,
		pattern = pattern,
		segments = segments,
		handler = h,
	})
}

route_get :: proc(r: ^Router, pattern: string, h: Handler) { route(r, .Get, pattern, h) }
route_post :: proc(r: ^Router, pattern: string, h: Handler) { route(r, .Post, pattern, h) }
route_put :: proc(r: ^Router, pattern: string, h: Handler) { route(r, .Put, pattern, h) }
route_patch :: proc(r: ^Router, pattern: string, h: Handler) { route(r, .Patch, pattern, h) }
route_delete :: proc(r: ^Router, pattern: string, h: Handler) { route(r, .Delete, pattern, h) }

// split_segments splits a path like "/todos/:id" into ["todos", ":id"].
// Leading/trailing slashes are stripped. An empty path yields an empty slice.
split_segments :: proc(path: string, allocator := context.allocator) -> []string {
	trimmed := strings.trim(path, "/")
	if len(trimmed) == 0 do return {}
	return strings.split(trimmed, "/")
}

// match finds a route matching the request. On success, populates req.url_params
// and returns the handler; returns nil if no match.
match :: proc(r: ^Router, req: ^Request) -> Handler {
	path_segments := split_segments(req.path, context.temp_allocator)

	for route in r.routes {
		if route.method != req.method do continue
		if _match_segments(route.segments, path_segments, req) {
			return route.handler
		}
	}
	return nil
}

_match_segments :: proc(pattern_segs: []string, path_segs: []string, req: ^Request) -> bool {
	// Wildcard suffix: pattern ends with "*".
	wildcard := len(pattern_segs) > 0 && pattern_segs[len(pattern_segs)-1] == "*"
	compare_len := len(pattern_segs)
	if wildcard do compare_len -= 1

	// If not wildcard, lengths must match exactly.
	if !wildcard && len(path_segs) != compare_len do return false
	// If wildcard, path must have at least the non-wildcard prefix.
	if wildcard && len(path_segs) < compare_len do return false

	// Clear any previous url_params.
	clear(&req.url_params)

	for i in 0..<compare_len {
		p := pattern_segs[i]
		if len(p) > 0 && p[0] == ':' {
			// Capture parameter.
			append(&req.url_params, path_segs[i])
		} else if p != path_segs[i] {
			return false
		}
	}
	return true
}

// === Middleware dispatch ===
//
// Odin proc literals do NOT capture outer variables, so we can't build a
// middleware chain with closures. Instead, we use a package-level pointer
// to the active server and store the current middleware index on the
// Request itself. A single `_continue` proc advances the chain.

@(private = "file")
_current_server: ^Server

// _continue is the `next` handler passed to each middleware.
// It advances the middleware index and dispatches the next middleware (or final handler).
_continue :: proc(req: ^Request, res: ^Response) {
	req._mw_idx += 1
	_dispatch_at(req._mw_idx, req, res)
}

// _dispatch_at runs the middleware at `idx`, or the final handler if idx is past the end.
_dispatch_at :: proc(idx: int, req: ^Request, res: ^Response) {
	if res.handled do return
	req._mw_idx = idx

	s := _current_server
	if idx >= len(s.middleware) {
		// End of middleware chain: run the final handler (router dispatch).
		_final_dispatch(req, res)
		return
	}
	mw := s.middleware[idx]
	mw(req, res, _continue)
}

// _final_dispatch runs the router and calls the matched route's handler.
_final_dispatch :: proc(req: ^Request, res: ^Response) {
	if res.handled do return
	s := _current_server
	h := match(&s.router, req)
	if h != nil {
		h(req, res)
		return
	}
	respond_text(res, S_404_NOT_FOUND, "404 Not Found\n")
}

// dispatch is the entry point for an incoming request.
// It sets the server global (if not set) and starts the middleware chain.
dispatch :: proc(s: ^Server, req: ^Request, res: ^Response) {
	_current_server = s
	req._mw_idx = 0
	_dispatch_at(0, req, res)
}
