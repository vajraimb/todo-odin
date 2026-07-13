#!/bin/bash
# Kill old, wait, start fresh on port 9753.
# Reads secrets from .env file or environment variables.
cd "$(dirname "$0")"

# Load .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Defaults
export AI_BASE_URL="${AI_BASE_URL:-https://openrouter.ai/api/v1}"
export AI_MODEL="${AI_MODEL:-z-ai/glm-5.2}"
export PUBLIC_URL="${PUBLIC_URL:-https://todo.vajraodin.ai}"
export TZ_OFFSET_HOURS="${TZ_OFFSET_HOURS:-8}"
export DB_PATH="${DB_PATH:-./data.db}"
export PORT="${PORT:-9753}"

# Check required
if [ -z "$TG_BOT_TOKEN" ]; then
    echo "ERROR: TG_BOT_TOKEN not set (put in .env or export)"
    exit 1
fi

echo ">> killing old processes..."
pkill -9 -f "./todoapp" 2>/dev/null
sleep 3

# Verify port is free
if lsof -i :${PORT} -P -n > /dev/null 2>&1; then
    echo "!! port ${PORT} still in use, force killing..."
    PID=$(lsof -ti :${PORT} 2>/dev/null)
    [ -n "$PID" ] && kill -9 $PID 2>/dev/null
    sleep 3
fi

echo ">> starting server on port ${PORT}..."
nohup ./todoapp > /tmp/todoapp.log 2>&1 &

sleep 2
if grep -q "listening" /tmp/todoapp.log && ! grep -q "Address_In_Use" /tmp/todoapp.log; then
    echo ">> server started OK"
    curl -s http://localhost:${PORT}/ | grep -o '<title>[^<]*</title>'
else
    echo "!! server failed to start:"
    cat /tmp/todoapp.log
fi
