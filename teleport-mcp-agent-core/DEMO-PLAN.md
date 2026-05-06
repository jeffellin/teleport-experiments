# Teleport + Amazon AgentCore: Identity-Aware AI Tooling Demo

## The Story

> "The same identity that controls your infrastructure access now controls your AI tool access —
> verified, auditable, and policy-driven at every hop."

Teleport authenticates the human. AgentCore enforces it at the AI layer. Cedar makes the policy
explicit and changeable without code deploys.

---

## Scenario 1: Verified Identity + Policy-Driven AI Tool Access

### Architecture

```
Developer
  │  tsh login ellinj.teleport.sh
  │  tsh mcp connect agentcore-gateway
  ↓
Teleport Proxy ──── issues JWT ────────────────────────────────────────────────────┐
  │  mcp+https://                                                                   │
  │  Authorization: Bearer <teleport-jwt>                                          │
  │  sub: none@nill.com                                             │
  │  roles: [mcp-user, aws-personal-admin, ...]                                    │
  ↓                                                                                 │
AgentCore Gateway                                                                   │
  │  Inbound Auth: validates JWT against                                            │
  │  https://ellinj.teleport.sh/.well-known/openid-configuration                   │
  │  Audience: mcp+https://<gateway-url>/mcp                ✓ already configured   │
  ↓                                                                                 │
REQUEST Interceptor Lambda  (passRequestHeaders: true)                             │
  │  1. Decode JWT from Authorization header (no re-verify, gateway already did)   │
  │  2. Call AVP IsAuthorized:                                                      │
  │       principal:  TeleportUser::"none@nill.com"                 │
  │       action:     Action::"invoke_tool"                                         │
  │       resource:   Tool::"get_order_tool"                                        │
  │       context:    { roles: ["mcp-user", ...] }                                  │
  │  3a. DENY  → return MCP error (tool Lambda never invoked)                      │
  │  3b. ALLOW → inject headers into forwarded request:                            │
  │         X-Teleport-User:  none@nill.com                         │
  │         X-Teleport-Roles: mcp-user,aws-personal-admin                          │
  ↓                                                                                 │
Tool Lambda                                                                         │
  │  Reads X-Teleport-User from event                                              │
  │  whoami_tool       → returns verified caller identity                          │
  │  get_order_tool    → scopes response to caller (per-user data)                 │
  │  update_order_tool → requires aws-personal-admin role (Cedar-gated)            │
  ↓                                                                                 │
Response                                                            Audit Trail    │
  │                                                              ┌──────────────┐  │
  └── MCP result to client                                       │ Teleport     │◄─┘
                                                                 │ (who called) │
                                                                 ├──────────────┤
                                                                 │ AVP          │
                                                                 │ (was it      │
                                                                 │  allowed?)   │
                                                                 └──────────────┘
```

### Components to Build

#### 1. Amazon Verified Permissions (AVP) Setup
- Create a policy store
- Define Cedar schema:
  - Entity types: `TeleportUser`, `TeleportRole`, `Tool`
  - Action: `invoke_tool`
- Define Cedar policies:

```cedar
// mcp-user can read orders
permit (
  principal in TeleportRole::"mcp-user",
  action == Action::"invoke_tool",
  resource == Tool::"get_order_tool"
);

// mcp-user can call whoami
permit (
  principal in TeleportRole::"mcp-user",
  action == Action::"invoke_tool",
  resource == Tool::"whoami_tool"
);

// only admins can mutate orders
permit (
  principal in TeleportRole::"aws-personal-admin",
  action == Action::"invoke_tool",
  resource == Tool::"update_order_tool"
);
```

#### 2. REQUEST Interceptor Lambda (new)
- Trigger: every tool call to AgentCore Gateway
- Input: full MCP request with `Authorization: Bearer <jwt>` header
- Logic:
  1. Decode JWT payload (base64, no signature check — gateway already validated)
  2. Extract `sub` and `roles` claims
  3. Extract tool name from MCP request body (`params.name`)
  4. Call `avp:IsAuthorized` with principal, action, resource, context
  5. On DENY: return interceptor response with MCP error
  6. On ALLOW: return interceptor response with injected headers
- IAM: needs `verifiedpermissions:IsAuthorized`
- Config: `passRequestHeaders: true` on gateway interceptor

#### 3. Tool Lambda (update existing)
- Add `whoami_tool` handler: returns `X-Teleport-User` and `X-Teleport-Roles` from event
- Update `get_order_tool`: include caller identity in response (simulate per-user scoping)
- Update `update_order_tool`: include caller identity in response
- Register `whoami_tool` as new tool target in AgentCore Gateway

#### 4. AgentCore Gateway Config Update
- Register interceptor Lambda as REQUEST interceptor with `passRequestHeaders: true`
- Add `whoami_tool` as a new tool target (zero inputSchema — no arguments)

#### 5. Test Script Update (`~/dev/teleport-agent/test-mcp.sh`)
- Add `whoami_tool` call
- Add `update_order_tool` call to demonstrate Cedar DENY for non-admin
- Pretty-print JSON responses

### Demo Script (what to show)

```
1. tsh mcp connect → tools/list
   Shows: whoami_tool, get_order_tool, update_order_tool

2. Call whoami_tool
   Shows: verified identity (sub, roles) extracted from Teleport JWT

3. Call get_order_tool
   Shows: Cedar ALLOW (mcp-user role), response scoped to caller

4. Call update_order_tool as mcp-user
   Shows: Cedar DENY — tool Lambda never invoked

5. Live-edit Cedar policy in AVP console to grant mcp-user update access
   Call update_order_tool again
   Shows: now ALLOW — zero code deploys, policy change is instant

6. Show Teleport audit log → every tools/call logged with identity
   Show AVP audit log → every IsAuthorized decision logged
```

### Key Message
- Teleport = authentication (cryptographic proof of who you are)
- AgentCore = enforcement point (JWT validated before any tool runs)
- Cedar = authorization (what you're allowed to do, changeable without code)
- Two independent audit trails: Teleport (who called) + AVP (was it permitted)

---

## Scenario 2: Identity Delegation via RFC 8693 Token Exchange (Future)

> Status: planned — pending Teleport RFC 8693 support or Keycloak shim

### The Problem Scenario 1 Doesn't Solve

In Scenario 1, the Tool Lambda knows *who* the caller is. But if that Lambda needs to call a
downstream OAuth-protected API *as that user* (not as a service account), it hits a wall:
no standard OAuth provider accepts a Teleport JWT as a subject token for OBO exchange.

### Architecture with Keycloak Shim

```
Teleport JWT (sub=jeffrey.ellin@...)
  ↓
AgentCore Gateway (validates JWT, same as Scenario 1)
  ↓
Tool Lambda:
  GetWorkloadAccessTokenForJWT(teleport-jwt)         ← AgentCore binds identity
  GetResourceOauth2Token(ON_BEHALF_OF, keycloak)     ← AgentCore calls Keycloak
      ↓
      Keycloak Token Exchange Endpoint (RFC 8693):
        subject_token      = <Teleport JWT>
        subject_token_type = urn:ietf:params:oauth:token-type:jwt
        audience           = <downstream-api-client>
      ↓
      Keycloak validates Teleport JWT via Teleport OIDC discovery
      Keycloak issues Keycloak token (same sub, Keycloak-signed)
  ↓
Downstream API (trusts Keycloak)
  Receives token carrying jeffrey.ellin@... as the caller
  Enforces per-user authorization natively
```

### Why Keycloak as the Shim

Keycloak is the only widely-deployed open-source IdP with native RFC 8693 token exchange.
It can be configured to:
- Trust Teleport as an external OIDC identity provider
- Accept a Teleport JWT as `subject_token` in a token exchange request
- Issue a Keycloak token preserving the original `sub` claim
- Scope the outbound token to a specific downstream audience

### Keycloak Setup Required
1. Deploy Keycloak (Docker for demo, or existing enterprise instance)
2. Create realm, configure Teleport as external IdP (OIDC, discovery URL)
3. Create agent client with `token-exchange` scope enabled
4. Map Teleport `sub` → Keycloak `sub` via identity provider mapper
5. Grant token exchange permission to the agent client
6. Enable `--features=preview` or `token-exchange` feature flag at startup

### AgentCore Setup Required
- Create OAuth Credential Provider pointing at Keycloak token endpoint
- Store Keycloak client secret in AWS Secrets Manager
- Configure `oauth2Flow=ON_BEHALF_OF_TOKEN_EXCHANGE` (RFC 8693)

### Product Argument for Teleport RFC 8693 Support

The Keycloak shim works but adds operational overhead: another IdP to deploy, configure,
and maintain. If Teleport natively supported RFC 8693 token exchange, the flow simplifies:

```
# Today (with Keycloak shim)
Teleport JWT → Keycloak exchange → Keycloak token → downstream API

# With native Teleport RFC 8693
Teleport JWT → Teleport exchange endpoint → scoped Teleport token → downstream API
```

Teleport already:
- Issues JWTs with OIDC discovery
- Has a concept of scoped app tokens
- Controls what downstream resources a user can access

Adding an RFC 8693 token exchange endpoint would allow Teleport-authenticated users to
seamlessly access OAuth-protected downstream services without any intermediate IdP.
The exchanged token would be Teleport-signed, Teleport-audited, and scoped to the
requested audience — consistent with Teleport's existing access control model.

This is the missing link for Teleport to be the **single identity plane** for both
infrastructure access and AI agent delegation.

---

## File Index

| File | Purpose |
|------|---------|
| `teleport.yaml` | Teleport agent config — app service, MCP gateway target |
| `test-mcp.sh` | CLI test script for MCP tool calls |
| `interceptor/` | REQUEST interceptor Lambda (to build) |
| `tools/` | Tool Lambda with identity-aware handlers (to build) |
| `cedar/` | Cedar schema + policies for AVP (to build) |
| `DEMO-PLAN.md` | This file |
