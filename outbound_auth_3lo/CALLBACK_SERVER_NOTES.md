# OAuth2 Callback Server Notes

This sample uses a local callback server (`oauth2_callback_server.py`) to finish
the OAuth 3LO flow. It is intentionally minimal and **not production-ready**.

## Data Flow (High Level)

1) Client invokes the AgentCore runtime.
   - Request headers include the user's JWT.
   - Response may stream an Authorization URL.

2) Client posts the user JWT to the callback server.
   - `POST /userIdentifier/token` with JSON:
     `{ "user_token": "<JWT>" }`
   - The callback server stores the user identifier **in memory**.

3) User completes consent at the OAuth provider.
   - Provider redirects the browser to:
     `GET /oauth2/callback?session_id=<session_uri>`

4) Callback server completes the flow with AgentCore Identity.
   - Calls `CompleteResourceTokenAuth(session_id, user_identifier)`
   - AgentCore Identity stores the provider tokens.

## Why This Sample Is Not Production-Ready

### 1) No per-user session mapping
The callback server stores only **one** user identifier in memory.
When the redirect arrives, it uses whatever user identifier was most recently
posted. This breaks in any multi-user or concurrent flow.

### 2) No durable storage
All state is in memory. A restart loses the user identifier and breaks the flow.

### 3) No user session verification
There is no cookie/session check or `state` binding. The server blindly accepts
the redirect and completes the flow using the stored user identifier.

### 4) No access control or rate limiting
The endpoints are unauthenticated and not hardened.

## Production Requirements (Summary)

- Use HTTPS and a public callback URL.
- Maintain a per-user or per-session mapping:
  - Bind `session_id` or `state` to the user identifier.
  - Store mapping in a durable, expiring store (Redis/DynamoDB).
- Validate the redirect:
  - Validate `state`, user session, and replay protection.
- Add auth on internal endpoints (`/userIdentifier/token`).
- Add logging, monitoring, and rate limiting.

## Required Callback Endpoints (Sample)

- `GET /ping`
- `POST /userIdentifier/token`
- `GET /oauth2/callback?session_id=<session_uri>`

These are sufficient for the notebook but must be hardened for production.
