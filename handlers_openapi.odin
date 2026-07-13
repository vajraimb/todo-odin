package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "web"

// OpenAPI 3.0 schema for the /api/v1 API.
// Served at GET /api/v1/openapi.json — agents can fetch this to understand the API.

// _openapi_schema returns the OpenAPI 3.0 JSON as a string (temp-allocated).
_openapi_schema :: proc() -> string {
	// Build manually as a string to avoid complex nested struct typing.
	// This is a complete OpenAPI 3.0 document.
	return `{
  "openapi": "3.0.3",
  "info": {
    "title": "Todo API",
    "description": "AI-friendly todo management API. Supports natural language input (when AI is configured), reminders, and multi-user isolation.\n\nAuthentication: session cookie OR Bearer token (Authorization: Bearer <token>).",
    "version": "1.0.0"
  },
  "servers": [
    {"url": "/api/v1", "description": "Relative to server root"}
  ],
  "components": {
    "securitySchemes": {
      "bearerAuth": {
        "type": "http",
        "scheme": "bearer"
      },
      "sessionCookie": {
        "type": "apiKey",
        "in": "cookie",
        "name": "session"
      }
    },
    "schemas": {
      "Todo": {
        "type": "object",
        "properties": {
          "id": {"type": "integer", "format": "int64"},
          "title": {"type": "string"},
          "completed": {"type": "boolean"}
        },
        "required": ["id", "title", "completed"]
      },
      "CreateTodoRequest": {
        "type": "object",
        "properties": {
          "title": {"type": "string", "description": "Todo title. When AI is configured, natural language like 'buy milk tomorrow 3pm' is parsed into title + reminder."}
        },
        "required": ["title"]
      },
      "UpdateTodoRequest": {
        "type": "object",
        "properties": {
          "title": {"type": "string", "nullable": true},
          "completed": {"type": "boolean", "nullable": true}
        }
      },
      "Counts": {
        "type": "object",
        "properties": {
          "total": {"type": "integer"},
          "active": {"type": "integer"},
          "completed": {"type": "integer"}
        }
      },
      "Token": {
        "type": "object",
        "properties": {
          "token": {"type": "string", "description": "The API token (only returned on creation)"},
          "name": {"type": "string"}
        }
      },
      "TokenInfo": {
        "type": "object",
        "properties": {
          "id": {"type": "integer"},
          "name": {"type": "string"},
          "created_at": {"type": "integer", "description": "Unix timestamp"},
          "last_used_at": {"type": "integer", "description": "Unix timestamp, 0 if never used"}
        }
      },
      "Error": {
        "type": "object",
        "properties": {
          "error": {"type": "string"}
        }
      }
    }
  },
  "security": [{"bearerAuth": []}, {"sessionCookie": []}],
  "paths": {
    "/todos": {
      "get": {
        "summary": "List todos",
        "description": "Returns all todos for the authenticated user, optionally filtered.",
        "parameters": [
          {"name": "filter", "in": "query", "schema": {"type": "string", "enum": ["all", "active", "completed"]}, "description": "Filter by completion status. Defaults to 'all'."}
        ],
        "responses": {
          "200": {"description": "List of todos", "content": {"application/json": {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/Todo"}}}}},
          "401": {"description": "Unauthorized", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}
        }
      },
      "post": {
        "summary": "Create a todo",
        "description": "Creates a new todo. When AI is configured, the title is parsed for natural language (e.g. 'buy milk tomorrow 3pm' creates a todo + reminder).",
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/CreateTodoRequest"}}}},
        "responses": {
          "201": {"description": "Created", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Todo"}}}},
          "401": {"description": "Unauthorized"},
          "422": {"description": "Validation error"}
        }
      }
    },
    "/todos/count": {
      "get": {
        "summary": "Get todo counts",
        "responses": {
          "200": {"description": "Counts", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Counts"}}}}
        }
      }
    },
    "/todos/toggle": {
      "post": {
        "summary": "Toggle all todos",
        "description": "If all todos are completed, marks all as active. Otherwise marks all as completed.",
        "responses": {
          "200": {"description": "Updated counts", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Counts"}}}}
        }
      }
    },
    "/todos/completed": {
      "delete": {
        "summary": "Delete all completed todos",
        "responses": {
          "200": {"description": "Updated counts", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Counts"}}}}
        }
      }
    },
    "/todos/{id}": {
      "patch": {
        "summary": "Update a todo",
        "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}],
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/UpdateTodoRequest"}}}},
        "responses": {
          "200": {"description": "Updated todo", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Todo"}}}},
          "404": {"description": "Not found"}
        }
      },
      "delete": {
        "summary": "Delete a todo",
        "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}],
        "responses": {
          "204": {"description": "Deleted"},
          "404": {"description": "Not found"}
        }
      }
    },
    "/tokens": {
      "get": {
        "summary": "List API tokens",
        "description": "Returns all API tokens for the authenticated user (without hashes).",
        "responses": {
          "200": {"description": "List of tokens", "content": {"application/json": {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/TokenInfo"}}}}}
        }
      },
      "post": {
        "summary": "Create an API token",
        "description": "Generates a new API token. The plaintext token is only returned once.",
        "requestBody": {"content": {"application/json": {"schema": {"type": "object", "properties": {"name": {"type": "string"}}}}}},
        "responses": {
          "201": {"description": "Created", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Token"}}}}
        }
      }
    },
    "/tokens/{id}": {
      "delete": {
        "summary": "Delete an API token",
        "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "integer"}}],
        "responses": {
          "204": {"description": "Deleted"},
          "404": {"description": "Not found"}
        }
      }
    }
  }
}`
}

// api_openapi serves the OpenAPI schema.
api_openapi :: proc(req: ^web.Request, res: ^web.Response) {
	web.respond(res, web.S_200_OK)
	web.set_content_type(res, .Json)
	web.write_string(res, _openapi_schema())
}

// api_manifest serves a simple text manifest describing what the API can do.
// This is for agents that want a quick overview without parsing OpenAPI.
api_manifest :: proc(req: ^web.Request, res: ^web.Response) {
	manifest := `Todo App API — Agent Manifest

This is a todo management service. You can create, list, update, and delete todos.
When AI is enabled, natural language input is parsed for todo title + optional reminder time.

Authentication:
  - Session cookie (from web UI)
  - Bearer token: Authorization: Bearer <token>
  - Create a token: POST /api/v1/tokens {"name":"my-agent"}

Endpoints:
  GET    /api/v1/todos?filter=all|active|completed  — list todos
  POST   /api/v1/todos {"title":"buy milk"}          — create (NL parsed if AI on)
  PATCH  /api/v1/todos/{id} {"title?":"...","completed?":true}  — update
  DELETE /api/v1/todos/{id}                          — delete
  GET    /api/v1/todos/count                         — {total, active, completed}
  POST   /api/v1/todos/toggle                        — toggle all
  DELETE /api/v1/todos/completed                     — delete completed
  POST   /api/v1/tokens {"name":"..."}               — create API token
  GET    /api/v1/tokens                              — list tokens
  DELETE /api/v1/tokens/{id}                         — delete token

Full OpenAPI spec: GET /api/v1/openapi.json
MCP server: POST /mcp (JSON-RPC 2.0 over HTTP)

Example:
  curl -H "Authorization: Bearer YOUR_TOKEN" /api/v1/todos
  curl -X POST -H "Authorization: Bearer YOUR_TOKEN" -H "Content-Type: application/json" \\
    -d '{"title":"call mom tomorrow 3pm"}' /api/v1/todos`

	web.respond_text(res, web.S_200_OK, manifest)
}
