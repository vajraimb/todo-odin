# Todo App (Odin + HTMX)

Self-contained personal todo application built in [Odin](https://odin-lang.org/). Zero external dependencies — HTTP server, SQLite, templating, all hand-written.

## Features

- **Web UI** — HTMX TodoMVC at `https://todo.vajraodin.ai`
- **Telegram bot** — `@nvidia_mbclaw_bot`, commands + natural language + voice
- **JSON API** — REST + OpenAPI schema + MCP server for AI agents
- **AI** — GLM-5.2 (via OpenRouter) for natural language parsing, Gemini for voice transcription
- **Reminders** — scheduler with dual push (Telegram + Bark for iPhone)
- **Auth** — API tokens, Passkey (WebAuthn), TG magic-link login
- **SQLite** — persistent, multi-user isolation

## Quick Start

```bash
# 1. Build (compiles SQLite + app)
./build.sh

# 2. Configure
cp .env.example .env
# Edit .env with your keys

# 3. Run
./start.sh
```

## Configuration

All via environment variables (or `.env` file):

| Variable | Required | Default | Description |
|---|---|---|---|
| `TG_BOT_TOKEN` | Yes | — | Telegram bot token from @BotFather |
| `AI_API_KEY` | No | — | LLM API key (OpenRouter/OpenAI/DeepSeek) |
| `AI_BASE_URL` | No | `https://api.openai.com/v1` | LLM API base URL |
| `AI_MODEL` | No | `gpt-4o-mini` | LLM model name |
| `GEMINI_API_KEY` | No | — | For voice transcription (Gemini 2.5 Flash) |
| `STT_PROVIDER` | No | `gemini` | `gemini` or `openai` |
| `DEFAULT_WEBHOOK_URL` | No | — | Bark/ntfy URL for push notifications |
| `PUBLIC_URL` | No | `https://todo.vajraodin.ai` | Public URL for login links |
| `TZ_OFFSET_HOURS` | No | `8` | Timezone offset from UTC |
| `DB_PATH` | No | `./data.db` | SQLite database path |
| `PORT` | No | `9753` | HTTP server port |

## Architecture

```
├── main.odin              # Startup + route registration
├── handlers_web.odin      # HTMX handlers (TodoMVC CRUD)
├── handlers_api.odin      # /api/v1 JSON REST API
├── handlers_mcp.odin      # MCP server (JSON-RPC, 8 tools)
├── handlers_openapi.odin  # OpenAPI schema + manifest
├── handlers_passkey.odin  # WebAuthn registration/login
├── handlers_settings.odin # Settings page + magic-link login
├── session.odin           # DB-backed session + cache
├── templates.odin         # HTML rendering (Odin procs, no template engine)
│
├── web/                   # Self-written HTTP server
│   ├── web.odin           # Types (Request/Response/Handler/Middleware)
│   ├── server.odin        # TCP + HTTP/1.1 parser + thread-per-connection
│   ├── router.odin        # Path matching + middleware dispatch
│   └── helpers.odin       # Headers/cookies/body parsing
│
├── store/                 # SQLite persistence
│   ├── sqlite.odin        # Hand-written C binding (~15 functions)
│   ├── db.odin            # Connection + migration system (v1-v6)
│   ├── todos.odin         # Users/sessions/todos CRUD
│   ├── reminders.odin     # Reminders + webhook management
│   └── auth.odin          # API tokens + passkeys + login tokens
│
├── ai/                    # AI integration
│   ├── client.odin        # curl-based HTTP client
│   ├── llm.odin           # Natural language → {title, remind_at}
│   └── stt.odin           # Voice transcription (Gemini/OpenAI)
│
├── tg/                    # Telegram bot
│   ├── api.odin           # TG Bot API client (long-polling)
│   └── bot.odin           # Command dispatch + voice + LLM
│
├── scheduler/             # Background reminder scheduler
│   └── reminders.odin     # 30s scan → TG push + webhook
│
├── vendor/sqlite/         # SQLite amalgamation + prebuilt static lib
└── static/                # Embedded static files (htmx.js, CSS)
```

## Telegram Bot Commands

```
/add <text>     Create todo (AI parses natural language)
/list           Show all todos
/done <id>      Mark completed
/undone <id>    Mark active
/delete <id>    Delete todo
/count          Show counts
/reminders      Show upcoming reminders
/webhook <url>  Set Bark/ntfy URL for iPhone push
/web            Get login link for web UI
/help           Show help
```

Send any text (without /) to create a todo. Send a voice message for AI transcription.

## API Endpoints

```
GET    /api/v1/todos           List todos (?filter=all|active|completed)
POST   /api/v1/todos           Create {"title":"..."}
PATCH  /api/v1/todos/:id       Update {"title?":"","completed?":true}
DELETE /api/v1/todos/:id       Delete
POST   /api/v1/todos/toggle    Toggle all
DELETE /api/v1/todos/completed Delete completed
GET    /api/v1/todos/count     Counts
POST   /api/v1/tokens          Create API token
GET    /api/v1/tokens          List tokens
DELETE /api/v1/tokens/:id      Delete token
GET    /api/v1/openapi.json    OpenAPI 3.0 schema
POST   /mcp                    MCP server (JSON-RPC)
```

Auth: session cookie OR `Authorization: Bearer <token>`.

## Build

Requires [Odin](https://odin-lang.org/) (dev-2026-06 or later) and a C compiler.

```bash
./build.sh   # Compiles SQLite amalgamation + links into binary
```

## Deployment (Cloudflare Tunnel)

```bash
# Install cloudflared
brew install cloudflared

# Quick tunnel (temporary URL)
cloudflared tunnel --url http://localhost:9753

# Named tunnel (permanent, needs Cloudflare account + domain)
cloudflared tunnel run --token <token>
```
