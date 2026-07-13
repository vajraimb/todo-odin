#!/bin/bash
# Start the todo app with AI (GLM-5.2 via OpenRouter) and TG bot enabled.
# Usage: ./run.sh
#
# Required env vars (set in .env or export manually):
#   TG_BOT_TOKEN  - Telegram bot token
#   AI_API_KEY    - OpenRouter API key
#
# Optional:
#   AI_BASE_URL   - default: https://openrouter.ai/api/v1
#   AI_MODEL      - default: z-ai/glm-5.2
#   DB_PATH       - default: ./data.db
#   PORT          - default: 8080

set -e

cd "$(dirname "$0")"

# Load .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Defaults
export AI_BASE_URL="${AI_BASE_URL:-https://openrouter.ai/api/v1}"
export AI_MODEL="${AI_MODEL:-z-ai/glm-5.2}"
export AI_STT_MODEL="${AI_STT_MODEL:-whisper-1}"
export DB_PATH="${DB_PATH:-./data.db}"
export PORT="${PORT:-8080}"

# Check required
if [ -z "$TG_BOT_TOKEN" ]; then
    echo "ERROR: TG_BOT_TOKEN not set"
    exit 1
fi
if [ -z "$AI_API_KEY" ]; then
    echo "WARNING: AI_API_KEY not set, AI features disabled"
fi

echo "Starting todo app..."
echo "  DB:       $DB_PATH"
echo "  Port:     $PORT"
echo "  AI:       ${AI_API_KEY:+enabled ($AI_MODEL)}${AI_API_KEY:-disabled}"
echo "  TG bot:   ${TG_BOT_TOKEN:+enabled}${TG_BOT_TOKEN:-disabled}"
echo ""

./todoapp
