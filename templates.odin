package main

import "core:fmt"
import "core:strings"
import "store"

// Page is the filter page the user is currently viewing.
Page :: enum {
	All,
	Active,
	Completed,
}

page_parse :: proc(val: string) -> Page {
	switch val {
	case "active":    return .Active
	case "completed": return .Completed
	case:             return .All
	}
}

page_from_path :: proc(path: string) -> Page {
	// Find the last '/' and parse the part after it.
	last_slash := -1
	for c, i in transmute([]u8)path {
		if c == '/' do last_slash = i
	}
	if last_slash < 0 do return .All
	return page_parse(path[last_slash+1:])
}

// Todo is the core data model.
Todo :: struct {
	id:        int,
	title:     string,
	completed: bool,
}

// Count is the footer count info.
Count :: struct {
	total:     int,
	active:    int,
	completed: int,
	oob:       bool,  // if true, render as out-of-band swap target
}

// List bundles data for the list template.
List :: struct {
	todos: []^Todo,
	count: Count,
	page:  Page,
}

// html_escape escapes a string for safe inclusion in HTML text content.
// Escapes & < > " '.
html_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	// First pass: compute required length.
	n := len(s)
	for c in transmute([]u8)s {
		switch c {
		case '&', '<':  n += 4
		case '>', '"':  n += 5
		case '\'':      n += 6
		case:
		}
	}
	if n == len(s) do return s  // nothing to escape

	out := make([dynamic]u8, 0, n, allocator)
	for c in transmute([]u8)s {
		switch c {
		case '&':  _append_str(&out, "&amp;")
		case '<':  _append_str(&out, "&lt;")
		case '>':  _append_str(&out, "&gt;")
		case '"':  _append_str(&out, "&quot;")
		case '\'': _append_str(&out, "&#39;")
		case:      append(&out, c)
		}
	}
	return transmute(string)(out[:])
}

_append_str :: proc(arr: ^[dynamic]u8, s: string) {
	append(arr, ..transmute([]u8)s)
}

// html_escape_attr escapes for use in an attribute value (double-quoted).
// Same as html_escape but always performed (no fast path).
html_escape_attr :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([dynamic]u8, 0, len(s) + 16, allocator)
	for c in transmute([]u8)s {
		switch c {
		case '&':  _append_str(&out, "&amp;")
		case '<':  _append_str(&out, "&lt;")
		case '>':  _append_str(&out, "&gt;")
		case '"':  _append_str(&out, "&quot;")
		case '\'': _append_str(&out, "&#39;")
		case:      append(&out, c)
		}
	}
	return transmute(string)(out[:])
}

// render_index renders the full HTML page.
render_index :: proc(l: List) -> string {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, `<!doctype html>
<html lang="en">
	<head>
		<meta charset="utf-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<title>Todo</title>
		<link rel="stylesheet" href="/todomvc-app-css@2.4.2-index.css">
		<style>
			.todo-list li .select-box {
				position: absolute; top: 0; left: 8px;
				height: 40px; width: 20px;
				text-align: center; line-height: 40px;
				opacity: 0; transition: opacity 0.1s;
			}
			.todo-list li:hover .select-box { opacity: 0.6; }
			.todo-list li .select-box input { margin: 0; }
			.todo-list li.selected { background: #e8f0fe; }
			.todo-list li .destroy { opacity: 0.3 !important; transition: opacity 0.1s; }
			.todo-list li:hover .destroy { opacity: 1 !important; }
			.bulk-bar {
				display: none; padding: 8px 15px; background: #f0f4ff;
				border-top: 1px solid #d0d8e8; font-size: 13px;
				align-items: center; gap: 12px;
			}
			.bulk-bar.visible { display: flex; }
			.bulk-bar button {
				padding: 4px 12px; border: 1px solid #ccc; border-radius: 3px;
				background: #fff; cursor: pointer; font-size: 12px;
			}
			.bulk-bar button:hover { background: #e8e8e8; }
			.bulk-bar button.danger { color: #d33; border-color: #d33; }
			.bulk-bar button.danger:hover { background: #fee; }
			.toggle-all-label { font-size: 12px; color: #888; cursor: pointer; }
			.header h1 { font-size: 60px; }
			.new-todo { font-size: 18px; }
		</style>
	</head>
	<body>
		<section class="todoapp">
			<header class="header">
				<h1>todos</h1>
				<form
					hx-post="/todos"
					hx-swap="afterbegin transition:true"
					hx-target=".todo-list"
					hx-on::before-request="htmx.find(this, 'input').value = ''"
				>
					<input class="new-todo" name="title" placeholder="What needs to be done?" autofocus>
				</form>
			</header>
`)
	render_list(&sb, l)
	strings.write_string(&sb, `
		</section>

		<footer class="info">
			<p>Double-click to edit · Check the box to multi-select</p>
		</footer>

		<script src="/htmx@1.9.5.min.js"></script>
		<script>
		// Multi-select logic
		function updateBulkBar() {
			const checked = document.querySelectorAll('.select-box input:checked');
			const bar = document.getElementById('bulk-bar');
			if (!bar) return;
			if (checked.length > 0) {
				bar.classList.add('visible');
				document.getElementById('bulk-count').textContent = checked.length + ' selected';
			} else {
				bar.classList.remove('visible');
			}
			// Highlight selected rows
			document.querySelectorAll('.todo-list li').forEach(li => {
				const cb = li.querySelector('.select-box input');
				if (cb) li.classList.toggle('selected', cb.checked);
			});
		}
		function bulkDelete() {
			const checked = document.querySelectorAll('.select-box input:checked');
			if (!confirm('Delete ' + checked.length + ' todo(s)?')) return;
			const ids = Array.from(checked).map(cb => cb.dataset.id);
			let pending = ids.length;
			ids.forEach(id => {
				fetch('/todos/' + id, {method: 'DELETE'}).then(() => {
					pending--;
					if (pending === 0) location.reload();
				});
			});
		}
		function selectAll() {
			const boxes = document.querySelectorAll('.select-box input');
			const allChecked = Array.from(boxes).every(b => b.checked);
			boxes.forEach(b => b.checked = !allChecked);
			updateBulkBar();
		}
		document.addEventListener('click', updateBulkBar);
		</script>
	</body>
</html>`)

	return strings.to_string(sb)
}

// render_list renders the #todos div (used for both full page and HTMX swaps).
render_list :: proc(sb: ^strings.Builder, l: List) {
	strings.write_string(sb, `<div id="todos">
	<section class="main">
		<input
			hx-target="#todos"
			hx-swap="outerHTML"
			hx-post="/todos/toggle"
			class="toggle-all"
			type="checkbox"
			id="toggle-all"
		>
		<label for="toggle-all" class="toggle-all-label">全部完成/取消</label>
		<ul class="todo-list">
`)
	for todo in l.todos {
		render_todo(sb, todo)
	}
	strings.write_string(sb, `		</ul>
	</section>

	<div class="bulk-bar" id="bulk-bar">
		<span id="bulk-count">0 selected</span>
		<button onclick="bulkDelete()" class="danger">Delete selected</button>
	</div>

	<footer class="footer">
`)
	render_count(sb, l.count)
	strings.write_string(sb, `
		<ul class="filters">
			<li>
`)
	render_filter_link(sb, "All", "/", .All, l.page)
	strings.write_string(sb, `			</li>
			<li>
`)
	render_filter_link(sb, "Active", "/active", .Active, l.page)
	strings.write_string(sb, `			</li>
			<li>
`)
	render_filter_link(sb, "Completed", "/completed", .Completed, l.page)
	strings.write_string(sb, `			</li>
		</ul>
	</footer>
</div>`)
}

render_filter_link :: proc(sb: ^strings.Builder, label: string, href: string, page: Page, current: Page) {
	if current == page {
		strings.write_string(sb, fmt.tprintf(`				<a class="selected">{}</a>`, label))
	} else {
		strings.write_string(sb, fmt.tprintf(
			`				<a hx-get="{}" hx-target="#todos" hx-push-url="true" href="{}">{}</a>`,
			href, href, label,
		))
	}
}

// render_todo renders a single <li> todo item.
render_todo :: proc(sb: ^strings.Builder, todo: ^Todo) {
	strings.write_string(sb, fmt.tprintf(
		`<li id="todo-{}"{}>
	<div class="select-box">
		<input type="checkbox" data-id="{}" onchange="updateBulkBar()">
	</div>
	<form
		hx-patch="/todos/{}"
		hx-target="#todo-{}"
		hx-swap="outerHTML"
		hx-trigger="submit, change"
	>
		<input name="id" value="{}" type="hidden">

		<div class="view">
			<input class="toggle" name="completed" type="checkbox"{}>
			<label hx-on:dblclick="htmx.addClass(htmx.closest(this, 'li'), 'editing')">{}</label>
			<button
				hx-delete="/todos/{}"
				hx-target="#todo-{}"
				hx-swap="outerHTML transition:true"
				type="button"
				style="cursor:pointer;"
				class="destroy"
			></button>
		</div>

		<input class="edit" name="title" value="{}">
	</form>
</li>`,

		todo.id,
		todo.completed ? " class=\"completed\"" : "",
		todo.id,
		todo.id,
		todo.id,
		todo.id,
		todo.completed ? " checked" : "",
		html_escape(todo.title),
		todo.id,
		todo.id,
		html_escape_attr(todo.title),
	))
}

// render_count renders the footer count + clear button.
render_count :: proc(sb: ^strings.Builder, c: Count) {
	strings.write_string(sb, `<div`)
	if c.oob {
		strings.write_string(sb, ` hx-swap-oob="true"`)
	}
	strings.write_string(sb, ` id="count">
			<div class="todo-count">
				<strong>`)
	strings.write_string(sb, fmt.tprintf(`{}</strong>`, c.active))

	if c.active == 1 {
		strings.write_string(sb, `<span> item left</span>`)
	} else {
		strings.write_string(sb, `<span> items left</span>`)
	}
	strings.write_string(sb, `
			</div>
`)

	if c.completed > 0 {
		strings.write_string(sb, `			<button
				hx-delete="/todos/completed"
				hx-target="#todos"
				hx-swap="outerHTML"
				class="clear-completed"
				style="z-index: 1;"
			>Clear completed</button>
`)
	}
	strings.write_string(sb, `		</div>`)
}

// render_settings_page renders the /settings page with passkey, token, and webhook management.
render_settings_page :: proc(tokens: []store.Token_Info, webhook_url: string, passkey_count: int, tg_chat: i64) -> string {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, fmt.tprintf(`<!doctype html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>Settings • Todo</title>
	<link rel="stylesheet" href="/todomvc-app-css@2.4.2-index.css">
	<style>
		.settings-page {{ max-width: 640px; margin: 40px auto; padding: 0 20px; font-family: -apple-system, sans-serif; }}
		.settings-page h1 {{ font-size: 24px; margin-bottom: 24px; }}
		.settings-section {{ background: #fff; border: 1px solid #e0e0e0; border-radius: 8px; padding: 20px; margin-bottom: 20px; }}
		.settings-section h2 {{ font-size: 16px; margin: 0 0 12px; }}
		.settings-section p {{ color: #888; font-size: 13px; margin: 0 0 12px; }}
		.btn {{ display: inline-block; padding: 8px 16px; border: 1px solid #ccc; border-radius: 4px; background: #f5f5f5; cursor: pointer; font-size: 14px; }}
		.btn:hover {{ background: #e8e8e8; }}
		.btn-primary {{ background: #4a90d9; color: #fff; border-color: #4a90d9; }}
		.btn-primary:hover {{ background: #357abd; }}
		.btn-danger {{ color: #d33; border-color: #d33; }}
		.btn-danger:hover {{ background: #fee; }}
		input[type="text"], input[type="url"] {{ width: 100%; padding: 8px; border: 1px solid #ccc; border-radius: 4px; font-size: 14px; box-sizing: border-box; }}
		.token-list {{ list-style: none; padding: 0; margin: 12px 0; }}
		.token-list li {{ display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-bottom: 1px solid #eee; font-size: 14px; }}
		.token-display {{ font-family: monospace; font-size: 12px; color: #d33; background: #fee; padding: 4px 8px; border-radius: 4px; margin: 8px 0; word-break: break-all; }}
		.status-msg {{ font-size: 13px; margin: 8px 0; }}
		.status-ok {{ color: #2a2; }}
		.status-err {{ color: #d33; }}
		.back-link {{ font-size: 14px; color: #4a90d9; text-decoration: none; }}
		.passkey-badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; }}
		.passkey-on {{ background: #d4edda; color: #155724; }}
		.passkey-off {{ background: #f8d7da; color: #721c24; }}
	</style>
</head>
<body>
<div class="settings-page">
	<a href="/" class="back-link">← Back to todos</a>
	<h1>Settings</h1>

	<div class="settings-section">
		<h2>Account</h2>
		<p>{}</p>
	</div>

	<div class="settings-section">
		<h2>Passkey <span class="passkey-badge {}">{}</span></h2>		<p>Register a passkey (Face ID / Touch ID / security key) for passwordless login.</p>
		<button class="btn btn-primary" onclick="registerPasskey()">Register Passkey</button>
		<button class="btn" onclick="loginPasskey()">Login with Passkey</button>
		<div id="passkey-status" class="status-msg"></div>
	</div>

	<div class="settings-section">
		<h2>API Tokens</h2>
		<p>Tokens for programmatic API access (agents, scripts, MCP).</p>
		<ul class="token-list">`, passkey_count > 0 ? "passkey-on" : "passkey-off", passkey_count > 0 ? fmt.tprintf("{} registered", passkey_count) : "none"))

	// Token list
	if len(tokens) == 0 {
		strings.write_string(&sb, `<li style="color:#888">No tokens yet</li>`)
	} else {
		for t in tokens {
			name := t.name if len(t.name) > 0 else "(unnamed)"
			strings.write_string(&sb, fmt.tprintf(
				`<li><span>{} <small style="color:#999">#{}</small></span><button class="btn btn-danger" onclick="deleteToken({})">Delete</button></li>`,
				html_escape(name), t.id, t.id,
			))
		}
	}

	strings.write_string(&sb, fmt.tprintf(`</ul>
		<div style="display:flex; gap:8px; margin-top:12px;">
			<input type="text" id="token-name" placeholder="Token name (optional)">
			<button class="btn btn-primary" onclick="createToken()">Create Token</button>
		</div>
		<div id="token-result"></div>
	</div>

	<div class="settings-section">
		<h2>Push Notification Webhook</h2>
		<p>Set a webhook URL for iOS push notifications (Bark, ntfy, Shortcuts). Reminders will POST to this URL.</p>
		<input type="url" id="webhook-url" placeholder="https://api.day.app/your-key" value="{}">
		<div style="margin-top:8px; display:flex; gap:8px;">
			<button class="btn btn-primary" onclick="setWebhook()">Save</button>
			<button class="btn btn-danger" onclick="clearWebhook()">Clear</button>
		</div>
		<div id="webhook-status" class="status-msg"></div>
	</div>

	<div class="settings-section">
		<h2>Agent Access</h2>
		<p style="margin-bottom:4px">OpenAPI schema: <a href="/api/v1/openapi.json">/api/v1/openapi.json</a></p>
		<p style="margin-bottom:4px">Manifest: <a href="/api/v1/manifest">/api/v1/manifest</a></p>
		<p style="margin-bottom:0">MCP endpoint: <code>POST /mcp</code></p>
	</div>
</div>

<script>
// === Passkey ===
async function registerPasskey() {{
	const status = document.getElementById('passkey-status');
	status.textContent = 'Starting...';
	try {{
		const resp = await fetch('/passkey/register/begin', {{method: 'POST'}});
		const opts = await resp.json();
		// Decode base64url to ArrayBuffer
		const dec = s => Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));
		opts.publicKey.challenge = dec(opts.publicKey.challenge);
		opts.publicKey.user.id = dec(opts.publicKey.user.id);
		const cred = await navigator.credentials.create(opts);
		// Encode ArrayBuffer to base64url
		const enc = buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
		const body = {{
			id: cred.id,
			rawId: cred.id,
			type: cred.type,
			response: {{
				attestationObject: enc(cred.response.attestationObject),
				clientDataJSON: enc(cred.response.clientDataJSON),
			}}
		}};
		// Also parse clientData for server verification
		const cd = JSON.parse(new TextDecoder().decode(cred.response.clientDataJSON));
		body.response.clientData = cd;
		const finishResp = await fetch('/passkey/register/finish', {{
			method: 'POST',
			headers: {{'Content-Type': 'application/json'}},
			body: JSON.stringify(body)
		}});
		if (finishResp.ok) {{
			status.textContent = 'Passkey registered!';
			status.className = 'status-msg status-ok';
			setTimeout(() => location.reload(), 1000);
		}} else {{
			const err = await finishResp.text();
			status.textContent = 'Failed: ' + err;
			status.className = 'status-msg status-err';
		}}
	}} catch(e) {{
		status.textContent = 'Error: ' + e.message;
		status.className = 'status-msg status-err';
	}}
}}

async function loginPasskey() {{
	const status = document.getElementById('passkey-status');
	status.textContent = 'Starting...';
	try {{
		const resp = await fetch('/passkey/login/begin', {{method: 'POST'}});
		const opts = await resp.json();
		const dec = s => Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));
		opts.publicKey.challenge = dec(opts.publicKey.challenge);
		const assertion = await navigator.credentials.get(opts);
		const enc = buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
		const cd = JSON.parse(new TextDecoder().decode(assertion.response.clientDataJSON));
		const body = {{
			id: assertion.id,
			rawId: assertion.id,
			type: assertion.type,
			response: {{
				authenticatorData: enc(assertion.response.authenticatorData),
				clientDataJSON: enc(assertion.response.clientDataJSON),
				signature: enc(assertion.response.signature),
				userHandle: assertion.response.userHandle ? enc(assertion.response.userHandle) : null,
				clientData: cd,
			}}
		}};
		const finishResp = await fetch('/passkey/login/finish', {{
			method: 'POST',
			headers: {{'Content-Type': 'application/json'}},
			body: JSON.stringify(body)
		}});
		if (finishResp.ok) {{
			status.textContent = 'Logged in!';
			status.className = 'status-msg status-ok';
		}} else {{
			const err = await finishResp.text();
			status.textContent = 'Failed: ' + err;
			status.className = 'status-msg status-err';
		}}
	}} catch(e) {{
		status.textContent = 'Error: ' + e.message;
		status.className = 'status-msg status-err';
	}}
}}

// === API Tokens ===
async function createToken() {{
	const name = document.getElementById('token-name').value;
	const result = document.getElementById('token-result');
	try {{
		const resp = await fetch('/api/v1/tokens', {{
			method: 'POST',
			headers: {{'Content-Type': 'application/json'}},
			body: JSON.stringify({{name: name}})
		}});
		const data = await resp.json();
		if (resp.ok) {{
			result.innerHTML = '<div class="token-display">' + data.token + '</div><div class="status-msg status-ok">Token created! Copy it now — it won\\'t be shown again.</div>';
			setTimeout(() => location.reload(), 5000);
		}} else {{
			result.innerHTML = '<div class="status-msg status-err">Failed: ' + (data.error || 'unknown') + '</div>';
		}}
	}} catch(e) {{
		result.innerHTML = '<div class="status-msg status-err">Error: ' + e.message + '</div>';
	}}
}}

async function deleteToken(id) {{
	if (!confirm('Delete this token?')) return;
	try {{
		const resp = await fetch('/api/v1/tokens/' + id, {{method: 'DELETE'}});
		if (resp.ok) location.reload();
	}} catch(e) {{}}
}}

// === Webhook ===
async function setWebhook() {{
	const url = document.getElementById('webhook-url').value;
	const status = document.getElementById('webhook-status');
	// We don't have a dedicated API endpoint for webhook, so we'll use a simple form post
	// Actually, let's add one. For now, we can use the TG bot's webhook setting mechanism.
	// Since there's no web API for webhook, we'll create one via a simple POST.
	try {{
		const resp = await fetch('/settings/webhook', {{
			method: 'POST',
			headers: {{'Content-Type': 'application/x-www-form-urlencoded'}},
			body: 'url=' + encodeURIComponent(url)
		}});
		if (resp.ok) {{
			status.textContent = 'Webhook saved!';
			status.className = 'status-msg status-ok';
		}} else {{
			status.textContent = 'Failed to save';
			status.className = 'status-msg status-err';
		}}
	}} catch(e) {{
		status.textContent = 'Error: ' + e.message;
		status.className = 'status-msg status-err';
	}}
}}

async function clearWebhook() {{
	document.getElementById('webhook-url').value = '';
	setWebhook();
}}
</script>
</body>
</html>`, webhook_url))

	return strings.to_string(sb)
}
