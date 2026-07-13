package store

import "core:c"
import "core:crypto/sha2"
import "core:encoding/base32"
import "core:encoding/hex"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

// === API Tokens ===

// Token_Info is metadata about a token (without the hash, for listing).
Token_Info :: struct {
	id:          i64,
	name:        string,
	created_at:  i64,
	last_used_at: i64,  // 0 if never used
}

// hash_token returns the SHA-256 hex hash of a token string.
hash_token :: proc(token: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)token)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:]))
}

// generate_token creates a random 32-byte token string (base32 encoded).
generate_token :: proc() -> string {
	buf: [32]u8
	n := rand.read(buf[:])
	assert(n == 32)
	return string(base32.encode(buf[:]))
}

// create_api_token generates a new token for a user, stores its hash, and returns the plaintext token.
// The plaintext is only returned once — store it safely.
create_api_token :: proc(db: Database, user_id: i64, name: string) -> (token: string, err: DB_Error) {
	token = generate_token()
	hash := hash_token(token)

	stmt, rc := prepare(db, "INSERT INTO api_tokens (user_id, token_hash, name, created_at) VALUES (?, ?, ?, ?);")
	if rc != OK {
		return "", fmt.tprintf("create_api_token prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)
	_ = bind_string(stmt, 2, hash)
	if len(name) > 0 {
		_ = bind_string(stmt, 3, name)
	} else {
		_ = bind_null(stmt, 3)
	}
	_ = bind_int64(stmt, 4, now_unix())

	rc = step(stmt)
	if rc != DONE {
		return "", fmt.tprintf("create_api_token step failed (rc=%d): %s", rc, err_str(db))
	}
	return token, nil
}

// lookup_api_token finds a user by their API token.
// Returns (user_id, true) if the token is valid. Updates last_used_at.
lookup_api_token :: proc(db: Database, token: string) -> (user_id: i64, found: bool) {
	hash := hash_token(token)

	stmt, rc := prepare(db, "SELECT id, user_id FROM api_tokens WHERE token_hash = ?;")
	if rc != OK do return 0, false
	defer finalize_safe(stmt)

	_ = bind_string(stmt, 1, hash)
	if !step_row(stmt) do return 0, false

	token_id := column_int64(stmt, 0)
	uid := column_int64(stmt, 1)

	// Update last_used_at (fire and forget).
	_touch_token(db, token_id)

	return uid, true
}

_touch_token :: proc(db: Database, token_id: i64) {
	stmt, rc := prepare(db, "UPDATE api_tokens SET last_used_at = ? WHERE id = ?;")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, now_unix())
	_ = bind_int64(stmt, 2, token_id)
	_ = step(stmt)
}

// list_api_tokens returns all tokens for a user (without hashes).
list_api_tokens :: proc(db: Database, user_id: i64) -> ([]Token_Info, DB_Error) {
	stmt, rc := prepare(db, "SELECT id, COALESCE(name, ''), created_at, COALESCE(last_used_at, 0) FROM api_tokens WHERE user_id = ? ORDER BY created_at DESC;")
	if rc != OK {
		return nil, fmt.tprintf("list_api_tokens prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)

	out := make([dynamic]Token_Info, 0, 4, context.temp_allocator)
	for step_row(stmt) {
		row := Token_Info{
			id = column_int64(stmt, 0),
			name = column_string(stmt, 1),
			created_at = column_int64(stmt, 2),
			last_used_at = column_int64(stmt, 3),
		}
		append(&out, row)
	}
	return out[:], nil
}

// delete_api_token deletes a token by id (scoped to user_id for security).
delete_api_token :: proc(db: Database, user_id: i64, token_id: i64) -> bool {
	stmt, rc := prepare(db, "DELETE FROM api_tokens WHERE id = ? AND user_id = ?;")
	if rc != OK do return false
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, token_id)
	_ = bind_int64(stmt, 2, user_id)
	rc = step(stmt)
	if rc != DONE do return false
	return changes(db) > 0
}

// === Passkey credentials ===

// Passkey_Cred is a stored passkey credential.
Passkey_Cred :: struct {
	id:            i64,
	user_id:       i64,
	credential_id: string,
	counter:       i64,
}

// store_create_passkey inserts a new passkey credential.
store_create_passkey :: proc(db: Database, user_id: i64, credential_id: string, public_key: []u8, transports: string) -> DB_Error {
	stmt, rc := prepare(db, "INSERT INTO passkey_credentials (user_id, credential_id, public_key, counter, transports, created_at) VALUES (?, ?, ?, 0, ?, ?);")
	if rc != OK {
		return fmt.tprintf("store_create_passkey prepare failed: %s", err_str(db))
	}
	defer finalize_safe(stmt)

	_ = bind_int64(stmt, 1, user_id)
	_ = bind_string(stmt, 2, credential_id)
	_ = bind_blob(stmt, 3, rawptr(&public_key[0]), c.int(len(public_key)), DESTRUCTOR_TRANSIENT)
	if len(transports) > 0 {
		_ = bind_string(stmt, 4, transports)
	} else {
		_ = bind_null(stmt, 4)
	}
	_ = bind_int64(stmt, 5, now_unix())

	rc = step(stmt)
	if rc != DONE {
		return fmt.tprintf("store_create_passkey step failed (rc=%d): %s", rc, err_str(db))
	}
	return nil
}

// store_find_passkey looks up a credential by its base64url credential_id.
store_find_passkey :: proc(db: Database, credential_id: string) -> (Passkey_Cred, bool) {
	stmt, rc := prepare(db, "SELECT id, user_id, counter FROM passkey_credentials WHERE credential_id = ?;")
	if rc != OK do return {}, false
	defer finalize_safe(stmt)

	_ = bind_string(stmt, 1, credential_id)
	if !step_row(stmt) do return {}, false

	return Passkey_Cred{
		id = column_int64(stmt, 0),
		user_id = column_int64(stmt, 1),
		credential_id = credential_id,
		counter = column_int64(stmt, 2),
	}, true
}

// store_update_passkey_counter updates the sign count for a credential.
store_update_passkey_counter :: proc(db: Database, cred_db_id: i64, counter: i64) {
	stmt, rc := prepare(db, "UPDATE passkey_credentials SET counter = ? WHERE id = ?;")
	if rc != OK do return
	defer finalize_safe(stmt)
	_ = bind_int64(stmt, 1, counter)
	_ = bind_int64(stmt, 2, cred_db_id)
	_ = step(stmt)
}

// === Stateless login tokens (no storage needed) ===
// Token format: <user_id>.<hex(sha256(user_id + SECRET))>
// The web handler verifies the hash and extracts user_id. No DB or file I/O.

LOGIN_SECRET :: "todo-app-secret-2026"

// create_login_token generates a stateless token encoding the user_id.
create_login_token :: proc(db: Database, token: string, user_id: i64) -> c.int {
	// This is now a no-op — token generation happens in generate_login_token.
	return 0
}

// generate_login_token creates a signed token for a user.
generate_login_token :: proc(user_id: i64) -> string {
	input := fmt.tprintf("{}.{}", user_id, LOGIN_SECRET)
	return fmt.tprintf("{}.{}", user_id, _sha256_hex(input))
}

// consume_login_token verifies a token and returns the user_id.
// No storage, no DB, no threading issues — pure computation.
consume_login_token :: proc(db: Database, token: string) -> (i64, bool) {
	// Split token at "."
	dot := strings.index_byte(token, '.')
	if dot < 0 do return 0, false

	user_id_str := token[:dot]
	received_hash := token[dot+1:]

	user_id, ok := strconv.parse_i64(user_id_str, 10)
	if !ok do return 0, false

	// Recompute hash
	input := fmt.tprintf("{}.{}", user_id, LOGIN_SECRET)
	expected_hash := _sha256_hex(input)

	if received_hash != expected_hash do return 0, false
	return user_id, true
}

// _sha256_hex returns hex(sha256(input))
_sha256_hex :: proc(input: string) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)input)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	return string(hex.encode(digest[:]))
}
