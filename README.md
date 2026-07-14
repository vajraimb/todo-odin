# Todo — Personal AI Todo Assistant

A self-contained personal todo application built in [Odin](https://odin-lang.org/). Zero external runtime dependencies — HTTP server, SQLite, templating, all hand-written in ~3500 lines of Odin.

## What It Does

- **Web UI** — HTMX TodoMVC with multi-select, inline editing, filters
- **Telegram bot** — commands, natural language, voice messages
- **WeChat bot** — via [wechat-ai](https://github.com/anxiong2025/wechat-ai) + MCP
- **JSON API** — REST + OpenAPI schema + MCP server (9 tools)
- **AI** — GLM-5.2 (OpenRouter) parses natural language; Gemini transcribes voice
- **Reminders** — scheduler with dual push (Telegram + Bark for iPhone)
- **Multi-user** — per-user todos, shared Bark reminders across users
- **Auth** — API tokens, Passkey (WebAuthn), TG/WeChat magic-link web login

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Telegram Bot Setup](#telegram-bot-setup)
- [WeChat Bot Setup](#wechat-bot-setup)
- [Bark Push Notifications](#bark-push-notifications)
- [Cloudflare Tunnel (Public URL)](#cloudflare-tunnel-public-url)
- [macOS Auto-Restart (launchd)](#macos-auto-restart-launchd)
- [Telegram Commands](#telegram-commands)
- [API Reference](#api-reference)
- [MCP Tools](#mcp-tools)
- [Build Details](#build-details)

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Odin Binary (~2MB)                     │
│                                                          │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌───────────┐  │
│  │ Web UI  │  │ TG Bot  │  │ Scheduler│  │  MCP/API  │  │
│  │ (HTMX)  │  │(long-   │  │ (30s scan│  │(9 tools)  │  │
│  │         │  │ poll)   │  │ → push)  │  │           │  │
│  └────┬────┘  └────┬────┘  └────┬─────┘  └─────┬─────┘  │
│       │            │            │               │        │
│       └────────────┴────────────┴───────────────┘        │
│                           │                              │
│                    ┌──────┴──────┐                       │
│                    │  SQLite DB  │                       │
│                    │ (embedded)  │                       │
│                    └─────────────┘                       │
└──────────────────────────────────────────────────────────┘

External services:
  OpenRouter (GLM-5.2)  →  natural language parsing
  Gemini API            →  voice transcription
  Telegram API          →  bot messages
  wechat-ai (Node.js)   →  WeChat bridge via MCP
  Bark (iOS app)        →  push notifications
  Cloudflare Tunnel     →  public HTTPS URL
```

```
├── main.odin              # Startup + route registration
├── handlers_web.odin      # HTMX web handlers
├── handlers_api.odin      # /api/v1 JSON REST API
├── handlers_mcp.odin      # MCP server (JSON-RPC, 9 tools)
├── handlers_openapi.odin  # OpenAPI 3.0 schema + manifest
├── handlers_passkey.odin  # WebAuthn registration/login
├── handlers_settings.odin # Settings page + magic-link login
├── session.odin           # DB-backed session + cache
├── templates.odin         # HTML rendering (Odin procs)
│
├── web/                   # Self-written HTTP/1.1 server
│   ├── web.odin           # Types (Request/Response/Handler)
│   ├── server.odin        # TCP + HTTP parser + thread pool
│   ├── router.odin        # Path matching + middleware
│   └── helpers.odin       # Headers/cookies/body parsing
│
├── store/                 # SQLite persistence layer
│   ├── sqlite.odin        # Hand-written C binding (~15 functions)
│   ├── db.odin            # Connection + migration system (v1-v7)
│   ├── todos.odin         # Users/sessions/todos CRUD
│   ├── reminders.odin     # Reminders + shared recipients
│   └── auth.odin          # API tokens + passkeys + login tokens
│
├── ai/                    # AI integration
│   ├── client.odin        # curl-based HTTP client
│   ├── llm.odin           # Natural language → {title, remind_at}
│   └── stt.odin           # Voice transcription (Gemini/OpenAI)
│
├── tg/                    # Telegram bot
│   ├── api.odin           # TG Bot API client (long-polling)
│   └── bot.odin           # Commands + voice + LLM + share
│
├── scheduler/             # Background reminder scheduler
│   └── reminders.odin     # 30s scan → TG + Bark + recipients
│
├── vendor/sqlite/         # SQLite amalgamation + static lib
└── static/                # Embedded files (htmx.js, CSS)
```

## Prerequisites

| Requirement | Version | How to install |
|---|---|---|
| [Odin](https://odin-lang.org/) | dev-2026-06 or later | [Install guide](https://odin-lang.org/docs/install/) |
| C compiler | any (clang/gcc) | macOS: Xcode CLI tools |
| [Cloudflare account](https://dash.cloudflare.com) | free | for public URL + tunnel |
| [Bark app](https://apps.apple.com/app/bark-push-notifications/id1403753865) | free | iOS push notifications |

## Quick Start

### 1. Clone & Build

```bash
git clone https://github.com/YOUR_USERNAME/todo-odin.git
cd todo-odin
./build.sh
```

This compiles the SQLite amalgamation and links it into the final binary.

### 2. Configure

```bash
cp .env.example .env
```

Edit `.env` with your keys (see [Configuration](#configuration) below).

### 3. Run

```bash
./start.sh
```

Or manually:

```bash
source .env
DB_PATH=./data.db PORT=9753 ./todoapp
```

Open `http://localhost:9753` in your browser.

## Configuration

All settings via environment variables (or `.env` file):

### Required

| Variable | Description |
|---|---|
| `TG_BOT_TOKEN` | Telegram bot token (from [@BotFather](https://t.me/BotFather)) |

### AI (for natural language + voice)

| Variable | Default | Description |
|---|---|---|
| `AI_API_KEY` | — | LLM API key (OpenRouter recommended) |
| `AI_BASE_URL` | `https://api.openai.com/v1` | LLM API base URL |
| `AI_MODEL` | `gpt-4o-mini` | LLM model (e.g. `z-ai/glm-5.2` on OpenRouter) |
| `GEMINI_API_KEY` | — | For voice transcription (Gemini 2.5 Flash) |
| `STT_PROVIDER` | `gemini` | `gemini` or `openai` |

### Push notifications

| Variable | Default | Description |
|---|---|---|
| `DEFAULT_WEBHOOK_URL` | — | Your Bark URL (see [Bark setup](#bark-push-notifications)) |

### Server

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_URL` | `http://localhost:9753` | Public URL for login links |
| `TZ_OFFSET_HOURS` | `8` | Your timezone offset from UTC |
| `DB_PATH` | `./data.db` | SQLite database file path |
| `PORT` | `9753` | HTTP server port |

### Example `.env`

```ini
TG_BOT_TOKEN=123456789:ABCdef...
AI_API_KEY=sk-or-v1-...
AI_BASE_URL=https://openrouter.ai/api/v1
AI_MODEL=z-ai/glm-5.2
GEMINI_API_KEY=AIza...
STT_PROVIDER=gemini
DEFAULT_WEBHOOK_URL=https://api.day.app/your-bark-key
PUBLIC_URL=https://todo.yourdomain.com
TZ_OFFSET_HOURS=8
DB_PATH=./data.db
PORT=9753
```

## Telegram Bot Setup

1. Open Telegram, search [@BotFather](https://t.me/BotFather)
2. Send `/newbot`, follow prompts to create a bot
3. Copy the token into `.env` as `TG_BOT_TOKEN`
4. Start the app, then send `/start` to your bot

The bot supports:
- **Text** → creates todo (AI parses if time keywords detected)
- **Voice** → transcribed via Gemini → creates todo
- **Commands** → see [Telegram Commands](#telegram-commands)

### Linking Web to TG

Send `/web` to the bot → receive a magic link → click it → web session is linked to your TG account. All todos are shared.

## WeChat Bot Setup

Uses [wechat-ai](https://github.com/anxiong2025/wechat-ai) as a bridge. The WeChat bot connects to our MCP server and uses AI to manage todos.

### 1. Install wechat-ai

```bash
npm i -g wechat-ai
```

### 2. Configure

Create `~/.wai/config.json`:

```json
{
    "defaultProvider": "openrouter",
    "providers": {
        "openrouter": {
            "type": "openai-compatible",
            "baseUrl": "https://openrouter.ai/api/v1",
            "model": "z-ai/glm-5.2",
            "apiKey": "YOUR_OPENROUTER_KEY"
        }
    },
    "channels": {
        "weixin": {
            "type": "weixin",
            "enabled": true
        }
    },
    "systemPrompt": "You are a todo assistant. Use MCP tools for all todo operations. Reply concisely in Chinese.",
    "mcpServers": {
        "todo": {
            "transport": "streamable-http",
            "url": "http://localhost:9753/mcp?token=YOUR_API_TOKEN"
        }
    }
}
```

> **Important**: Use `"type": "openai-compatible"` (not `"claw-agent"`) to prevent the AI from using bash/file tools instead of MCP tools.

### 3. Get an API token

First, log into the web UI (via TG `/web` magic link), then go to `/settings` → create a token. Use that token in the MCP URL above.

### 4. Start

```bash
wechat-ai
```

Scan the QR code with WeChat. Then send messages in WeChat:
- "加个买牛奶"
- "我的todo列表"
- "给我网页登录链接"

## Bark Push Notifications

[Bark](https://apps.apple.com/app/bark-push-notifications/id1403753865) is a free iOS app for receiving push notifications via a simple URL.

### Setup

1. Install Bark from App Store
2. Open the app → copy your URL (e.g. `https://api.day.app/XXXXXXXXX`)
3. Set it as your webhook:

**Via Telegram:**
```
/webhook https://api.day.app/your-key
```

**Via web settings page:** Open `/settings` → paste URL → Save

**Via environment variable:** Set `DEFAULT_WEBHOOK_URL` in `.env`

### How it works

When a reminder fires, the scheduler sends a POST to your Bark URL → your iPhone shows a system push notification (lock screen + banner + sound).

### Sharing reminders with family

Share a reminder to another person's Bark:

```
/share <todo_id> https://api.day.app/their-key 儿子
```

Both you and the recipient get Bark pushes when the reminder fires.

## Cloudflare Tunnel (Public URL)

Exposes your local server to the internet with HTTPS — required for Passkey (WebAuthn) and public access.

### Quick tunnel (temporary URL)

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:9753
```

Gives you a `*.trycloudflare.com` URL. Works as long as the process runs.

### Named tunnel (permanent URL)

1. Go to [Cloudflare dashboard](https://dash.cloudflare.com) → register a domain
2. **Zero Trust** → **Networks** → **Tunnels** → **Create tunnel**
3. Name it, copy the token
4. Run the tunnel:
   ```bash
   cloudflared tunnel run --token YOUR_TOKEN
   ```
5. Configure **Public Hostname**: `todo.yourdomain.com` → `HTTP` → `localhost:9753`
6. Set `PUBLIC_URL=https://todo.yourdomain.com` in `.env`

## macOS Auto-Restart (launchd)

Keep the app running across reboots and crashes.

### 1. Create plist

Create `~/Library/LaunchAgents/com.user.todoapp.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.todoapp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/todo-odin/todoapp</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/path/to/todo-odin</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TG_BOT_TOKEN</key><string>your-token</string>
        <key>AI_API_KEY</key><string>your-key</string>
        <!-- Add all env vars from .env -->
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/todoapp.log</string>
    <key>StandardErrorPath</key><string>/tmp/todoapp.log</string>
</dict>
</plist>
```

### 2. Load

```bash
launchctl load ~/Library/LaunchAgents/com.user.todoapp.plist
```

### Management

```bash
launchctl list | grep todoapp          # status
launchctl unload ~/Library/LaunchAgents/com.user.todoapp.plist  # stop
launchctl load ~/Library/LaunchAgents/com.user.todoapp.plist    # start
tail -f /tmp/todoapp.log               # logs
```

## Telegram Commands

| Command | Description |
|---|---|
| `/add <text>` | Create todo (AI parses natural language + reminders) |
| `/list` | Show all todos |
| `/done <id>` | Mark completed |
| `/undone <id>` | Mark active |
| `/delete <id>` | Delete todo |
| `/count` | Show counts |
| `/reminders` | Show upcoming reminders |
| `/webhook <url>` | Set Bark URL for iOS push |
| `/share <id> <url> [label]` | Share reminder to another Bark |
| `/unshare <id> <url>` | Remove shared recipient |
| `/web` | Get web login link |
| `/help` | Show help |

Send plain text (no command) → creates todo. Send voice → transcribed → creates todo.

## API Reference

### Authentication

All `/api/v1/*` endpoints accept:
- **Session cookie** (from web UI), OR
- **Bearer token**: `Authorization: Bearer <token>`

Create tokens at `/settings` or via `POST /api/v1/tokens`.

### Endpoints

```
GET    /api/v1/todos            List (?filter=all|active|completed)
POST   /api/v1/todos            Create {"title":"..."}
PATCH  /api/v1/todos/:id        Update {"title?":"","completed?":true}
DELETE /api/v1/todos/:id        Delete
GET    /api/v1/todos/count      {total, active, completed}
POST   /api/v1/todos/toggle     Toggle all
DELETE /api/v1/todos/completed  Delete completed
POST   /api/v1/tokens           Create API token
GET    /api/v1/tokens           List tokens
DELETE /api/v1/tokens/:id       Delete token
GET    /api/v1/openapi.json     OpenAPI 3.0 schema
GET    /api/v1/manifest         Plain-text API manifest
POST   /mcp                     MCP server (JSON-RPC 2.0)
```

## MCP Tools

The MCP server exposes 9 tools for AI agents (WeChat, Claude, etc.):

| Tool | Description |
|---|---|
| `list_todos` | List todos (optional filter) |
| `create_todo` | Create with natural language |
| `update_todo` | Update title/completion |
| `delete_todo` | Delete by id |
| `get_counts` | Total/active/completed counts |
| `toggle_all` | Toggle all completion |
| `clear_completed` | Delete completed |
| `list_reminders` | List upcoming reminders |
| `get_web_login_link` | Generate web login URL |

Connect from any MCP client:

```json
{
  "mcpServers": {
    "todo": {
      "transport": "streamable-http",
      "url": "http://localhost:9753/mcp?token=YOUR_TOKEN"
    }
  }
}
```

## Build Details

### Requirements

- [Odin](https://odin-lang.org/) dev-2026-06 or later
- C compiler (clang/gcc)

### Build

```bash
./build.sh
```

This script:
1. Compiles `vendor/sqlite/sqlite3.c` into a static library (`libsqlite3.a`)
2. Compiles the Odin source and links with SQLite
3. Output: `./todoapp` (~2MB binary)

### How SQLite is integrated

SQLite is vendored as the [amalgamation](https://www.sqlite.org/amalgamation.html) (single `sqlite3.c` file). A minimal C binding (~15 functions) is hand-written in `store/sqlite.odin`. No ORM, no abstraction layer — just `prepare_v2`, `step`, `bind_*`, `column_*`.

## License

MIT
