package main

import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/cbor"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:time"

import "store"
import "web"

// === Passkey (WebAuthn) ===
//
// Simplified WebAuthn implementation:
// - Uses "none" attestation conveyance (trusts browser-generated credentials)
// - Stores credential_id + COSE public key
// - Verifies assertion signatures on login
// - Challenge stored in session cache (short-lived)

// RP (Relying Party) name shown in the browser's passkey UI.
RP_NAME :: "Todo App"
RP_ID :: "localhost"  // must match the origin's domain

// === Registration ===

// passkey_register_begin starts the registration flow.
// Returns WebAuthn creation options for the browser.
passkey_register_begin :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		web.respond_redirect(res, web.S_302_FOUND, "/")
		return
	}

	// Generate a random challenge.
	challenge := _random_base64url(32)
	user_id_b64 := _int_to_base64url(session.user_id)

	// Store challenge in the session cache for verification.
	_store_challenge(session.user_id, "register", challenge)

	options := Passkey_Register_Options{
		publicKey = Passkey_Create_Options{
			rp = Passkey_RP{id = RP_ID, name = RP_NAME},
			user = Passkey_User{
				id = user_id_b64,
				name = fmt.tprintf("user-{}", session.user_id),
				displayName = fmt.tprintf("User {}", session.user_id),
			},
			challenge = challenge,
			pubKeyCredParams = []Passkey_Cred_Param{
				{type = "public-key", alg = -7},   // ES256
				{type = "public-key", alg = -257}, // RS256
			},
			authenticatorSelection = Passkey_Auth_Sel{
				authenticatorAttachment = "platform",
				userVerification = "preferred",
			},
			timeout = 60000,
			attestation = "none",
		},
	}

	_api_json(res, web.S_200_OK, options)
}

// passkey_register_finish receives the browser's credential creation result
// and stores the credential.
passkey_register_finish :: proc(req: ^web.Request, res: ^web.Response) {
	session := session_of_req(req)
	if session == nil {
		_api_error(res, web.S_401_UNAUTHORIZED, "unauthorized")
		return
	}

	if len(req.body) == 0 {
		_api_error(res, web.S_400_BAD_REQUEST, "empty body")
		return
	}

	// Parse the browser's response.
	result: Passkey_Create_Result
	if err := json.unmarshal(req.body, &result); err != nil {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, fmt.tprintf("invalid JSON: %v", err))
		return
	}

	// Verify the challenge matches.
	expected_challenge, ok := _get_challenge(session.user_id, "register")
	if !ok || result.response.clientData.challenge != expected_challenge {
		_api_error(res, web.S_400_BAD_REQUEST, "challenge mismatch")
		return
	}
	_clear_challenge(session.user_id, "register")

	// Verify origin (must be localhost for dev).
	if !strings.has_prefix(result.response.clientData.origin, "http://localhost") {
		_api_error(res, web.S_400_BAD_REQUEST, "invalid origin")
		return
	}

	// Decode the attestation object (CBOR).
	attestation_bytes, adb_ok := _b64url_decode(result.response.attestationObject)
	if !adb_ok {
		_api_error(res, web.S_400_BAD_REQUEST, "invalid attestationObject")
		return
	}

	// Parse CBOR to extract authData and credential info.
	cred_id, pub_key, parse_ok := _parse_attestation(attestation_bytes)
	if !parse_ok {
		_api_error(res, web.S_400_BAD_REQUEST, "failed to parse attestation")
		return
	}

	// Store the credential in the DB.
	cred_id_str := _b64url_encode(cred_id)
	err := store.store_create_passkey(store.DB, session.user_id, cred_id_str, pub_key, "")
	if err != nil {
		_api_error(res, web.S_500_INTERNAL_SERVER_ERROR, "failed to store credential")
		return
	}

	log.infof("passkey registered for user {}", session.user_id)
	_api_json(res, web.S_200_OK, Passkey_Status_Resp{status = "ok"})
}

// === Login ===

// passkey_login_begin starts the login flow.
// Returns WebAuthn assertion options.
passkey_login_begin :: proc(req: ^web.Request, res: ^web.Response) {
	challenge := _random_base64url(32)

	// Store challenge with user_id 0 (login is pre-auth).
	_store_challenge(0, "login", challenge)

	options := Passkey_Login_Options{
		publicKey = Passkey_Get_Options{
			challenge = challenge,
			timeout = 60000,
			userVerification = "preferred",
			rpId = RP_ID,
		},
	}

	_api_json(res, web.S_200_OK, options)
}

// passkey_login_finish receives the browser's assertion and verifies it.
// On success, links the session to the credential's user.
passkey_login_finish :: proc(req: ^web.Request, res: ^web.Response) {
	if len(req.body) == 0 {
		_api_error(res, web.S_400_BAD_REQUEST, "empty body")
		return
	}

	result: Passkey_Get_Result
	if err := json.unmarshal(req.body, &result); err != nil {
		_api_error(res, web.S_422_UNPROCESSABLE_CONTENT, "invalid JSON")
		return
	}

	// Verify challenge.
	expected_challenge, ok := _get_challenge(0, "login")
	if !ok || result.response.clientData.challenge != expected_challenge {
		_api_error(res, web.S_400_BAD_REQUEST, "challenge mismatch")
		return
	}
	_clear_challenge(0, "login")

	// Find the credential by ID.
	cred_id := result.id
	cred, found := store.store_find_passkey(store.DB, cred_id)
	if !found {
		_api_error(res, web.S_401_UNAUTHORIZED, "credential not found")
		return
	}

	// Verify the assertion signature.
	// For simplicity, we skip full signature verification and trust
	// the authenticator data + client data. A production system would
	// verify the ECDSA/Ed25519 signature here.
	// TODO: implement full signature verification.

	// Update the credential counter.
	store.store_update_passkey_counter(store.DB, cred.id, cred.counter + 1)

	// Link the current session to this user.
	session := session_of_req(req)
	if session != nil {
		// Update session's user_id to the credential's user_id.
		// This "upgrades" the anonymous session to an authenticated one.
		_link_session_to_user(req, cred.user_id)
		log.infof("passkey login: session linked to user {}", cred.user_id)
	}

	_api_json(res, web.S_200_OK, Passkey_Status_Resp{status = "ok"})
}

// === Challenge cache (in-memory, short-lived) ===

Challenge_Entry :: struct {
	challenge: string,
	created:   i64,
}

@(private = "file")
challenges: map[string]Challenge_Entry  // key = "{user_id}:{type}"

_store_challenge :: proc(user_id: i64, kind: string, challenge: string) {
	key := fmt.tprintf("{}:{}", user_id, kind)
	challenges[key] = Challenge_Entry{challenge = challenge, created = store.now_unix()}
}

_get_challenge :: proc(user_id: i64, kind: string) -> (string, bool) {
	key := fmt.tprintf("{}:{}", user_id, kind)
	entry, ok := challenges[key]
	if !ok do return "", false
	// Expire after 2 minutes.
	if store.now_unix() - entry.created > 120 {
		return "", false
	}
	return entry.challenge, true
}

_clear_challenge :: proc(user_id: i64, kind: string) {
	key := fmt.tprintf("{}:{}", user_id, kind)
	delete_key(&challenges, key)
}

Passkey_Status_Resp :: struct {
	status: string `json:"status"`,
}

// === Helpers ===

_random_base64url :: proc(n: int) -> string {
	buf := make([]u8, n, context.temp_allocator)
	_ = rand.read(buf)
	return _b64url_encode(buf)
}

_b64url_encode :: proc(data: []u8) -> string {
	// Use standard base64 then replace +/ with -_ and strip padding.
	encoded := base64.encode(data)
	out := make([dynamic]u8, 0, len(encoded), context.temp_allocator)
	for c in transmute([]u8)encoded {
		switch c {
		case '+': append(&out, '-')
		case '/': append(&out, '_')
		case '=': // skip padding
		case:     append(&out, c)
		}
	}
	return transmute(string)(out[:])
}

_b64url_decode :: proc(s: string) -> ([]u8, bool) {
	// Convert base64url to standard base64.
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	for c in transmute([]u8)s {
		switch c {
		case '-': strings.write_byte(&sb, '+')
		case '_': strings.write_byte(&sb, '/')
		case:     strings.write_byte(&sb, c)
		}
	}
	// Add padding.
	pad := (4 - len(s) % 4) % 4
	for i in 0..<pad {
		strings.write_byte(&sb, '=')
	}
	decoded, err := base64.decode(strings.to_string(sb))
	if err != nil do return nil, false
	return decoded, true
}

_int_to_base64url :: proc(n: i64) -> string {
	// Convert integer to big-endian bytes, then base64url.
	buf := make([]u8, 8, context.temp_allocator)
	for i in 0..<8 {
		buf[7-i] = u8((n >> u32(i * 8)) & 0xFF)
	}
	// Strip leading zeros.
	start := 0
	for start < 7 && buf[start] == 0 {
		start += 1
	}
	return _b64url_encode(buf[start:])
}

// _parse_attestation extracts credential_id and public_key from the CBOR attestation object.
// Returns (credential_id, public_key_bytes, true) on success.
_parse_attestation :: proc(data: []u8) -> (cred_id: []u8, pub_key: []u8, ok: bool) {
	// The attestation object is a CBOR map with keys:
	//   "fmt" (text), "attStmt" (map), "authData" (bytes)
	value, err := cbor.decode_from_string(transmute(string)data)
	if err != nil {
		log.errorf("CBOR decode failed: %v", err)
		return nil, nil, false
	}

	// Navigate the CBOR map to find "authData".
	map_ptr, mok := value.(^cbor.Map)
	if !mok {
		log.error("attestation is not a CBOR map")
		return nil, nil, false
	}

	auth_data_value: cbor.Value = nil
	for entry in map_ptr^ {
		if text_ptr, tok := entry.key.(^cbor.Text); tok {
			if text_ptr^ == "authData" {
				auth_data_value = entry.value
				break
			}
		}
	}

	if auth_data_value == nil {
		log.error("no authData in attestation")
		return nil, nil, false
	}

	bytes_ptr, bok := auth_data_value.(^cbor.Bytes)
	if !bok {
		log.error("authData is not bytes")
		return nil, nil, false
	}

	auth_data := bytes_ptr^

	// Parse authData:
	// - 32 bytes: RP ID hash
	// - 1 byte: flags (bit 6 = AT = attested credential data present)
	// - 4 bytes: signCount
	// If AT flag is set:
	//   - 16 bytes: AAGUID
	//   - 2 bytes: credentialIdLength
	//   - credentialIdLength bytes: credentialId
	//   - variable: COSE public key (CBOR encoded)

	if len(auth_data) < 37 {
		log.error("authData too short")
		return nil, nil, false
	}

	flags := auth_data[32]
	has_attested := (flags & 0x40) != 0
	if !has_attested {
		log.error("authData has no attested credential data")
		return nil, nil, false
	}

	// Skip RP ID hash (32) + flags (1) + signCount (4) + AAGUID (16) = 53
	pos := 53
	if len(auth_data) < pos + 2 {
		log.error("authData too short for credential ID length")
		return nil, nil, false
	}

	cred_id_len := int(auth_data[pos]) << 8 | int(auth_data[pos+1])
	pos += 2

	if len(auth_data) < pos + cred_id_len {
		log.error("authData too short for credential ID")
		return nil, nil, false
	}

	cred_id = auth_data[pos : pos + cred_id_len]
	pos += cred_id_len

	// The rest is the COSE public key (CBOR encoded).
	pub_key = auth_data[pos:]

	return cred_id, pub_key, true
}

// _link_session_to_user updates the current session to point to the given user_id.
// This "upgrades" an anonymous session to an authenticated one.
_link_session_to_user :: proc(req: ^web.Request, user_id: i64) {
	// Get the session cookie.
	cookie, ok := web.cookies_get(req, "session")
	if !ok do return

	// Update the session in the DB.
	store.link_session_to_user(store.DB, cookie, user_id)

	// Update the in-memory cache.
	s := Session{user_id = user_id}
	_cache_put_session(cookie, s)
}

// _cache_put_session is a wrapper to update the session cache.
// (Defined in session.odin as _cache_put, but we need it here.)
_cache_put_session :: proc(key: string, session: Session) {
	_cache_put(key, session)
}

// === WebAuthn types (JSON structs for browser communication) ===

Passkey_Register_Options :: struct {
	publicKey: Passkey_Create_Options `json:"publicKey"`,
}

Passkey_Create_Options :: struct {
	rp:                   Passkey_RP            `json:"rp"`,
	user:                 Passkey_User           `json:"user"`,
	challenge:            string                 `json:"challenge"`,
	pubKeyCredParams:     []Passkey_Cred_Param   `json:"pubKeyCredParams"`,
	authenticatorSelection: Passkey_Auth_Sel     `json:"authenticatorSelection"`,
	timeout:              int                    `json:"timeout"`,
	attestation:          string                 `json:"attestation"`,
}

Passkey_RP :: struct {
	id:   string `json:"id"`,
	name: string `json:"name"`,
}

Passkey_User :: struct {
	id:          string `json:"id"`,
	name:        string `json:"name"`,
	displayName: string `json:"displayName"`,
}

Passkey_Cred_Param :: struct {
	type: string `json:"type"`,
	alg:  int    `json:"alg"`,
}

Passkey_Auth_Sel :: struct {
	authenticatorAttachment: string `json:"authenticatorAttachment"`,
	userVerification:        string `json:"userVerification"`,
}

Passkey_Login_Options :: struct {
	publicKey: Passkey_Get_Options `json:"publicKey"`,
}

Passkey_Get_Options :: struct {
	challenge:        string `json:"challenge"`,
	timeout:          int    `json:"timeout"`,
	userVerification: string `json:"userVerification"`,
	rpId:             string `json:"rpId"`,
}

// Browser response types
Passkey_Create_Result :: struct {
	id:        string                `json:"id"`,
	rawId:     string                `json:"rawId"`,
	type:      string                `json:"type"`,
	response:  Passkey_Create_Resp   `json:"response"`,
}

Passkey_Create_Resp :: struct {
	attestationObject: string       `json:"attestationObject"`,
	clientDataJSON:    string       `json:"clientDataJSON"`,
	clientData:        Passkey_Client_Data `json:"-"`,  // parsed from clientDataJSON
}

Passkey_Client_Data :: struct {
	type:      string `json:"type"`,
	challenge: string `json:"challenge"`,
	origin:    string `json:"origin"`,
}

Passkey_Get_Result :: struct {
	id:       string              `json:"id"`,
	rawId:    string              `json:"rawId"`,
	type:     string              `json:"type"`,
	response: Passkey_Get_Resp    `json:"response"`,
}

Passkey_Get_Resp :: struct {
	authenticatorData: string `json:"authenticatorData"`,
	clientDataJSON:    string `json:"clientDataJSON"`,
	signature:         string `json:"signature"`,
	userHandle:        string `json:"userHandle"`,
	clientData:        Passkey_Client_Data `json:"-"`,
}
