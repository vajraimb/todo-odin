#!/bin/bash
# Build script for the todo app.
# Compiles SQLite (if needed) and links it into the final binary.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Recompile SQLite static library if missing or source changed.
if [ ! -f vendor/sqlite/libsqlite3.a ] || [ vendor/sqlite/sqlite3.c -nt vendor/sqlite/libsqlite3.a ]; then
    echo ">> compiling sqlite3 amalgamation..."
    cc -c -O2 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
        vendor/sqlite/sqlite3.c -o vendor/sqlite/sqlite3.o
    ar rcs vendor/sqlite/libsqlite3.a vendor/sqlite/sqlite3.o
    rm -f vendor/sqlite/sqlite3.o
fi

# Build the app.
echo ">> building todo app..."
odin build . -out:./todoapp -extra-linker-flags:"vendor/sqlite/libsqlite3.a" || exit 1

echo ">> done. run with: DB_PATH=./data.db PORT=8080 ./todoapp"
