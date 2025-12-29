# AgentCore Integration

This document describes how the Spring Cloud Gateway integrates with **AWS Bedrock AgentCore Gateway** through JWT transformation and routing.

**Status**: ✅ **Working and Deployed**

## Overview

The gateway acts as a JWT transformation proxy that:

1. ✅ Receives Teleport JWTs from authenticated users
2. ✅ Validates Teleport JWT signatures (optional, configurable)
3. ✅ Extracts user identity (`username`) and roles from Teleport JWT
4. ✅ Mints new JWTs signed by the gateway that AgentCore trusts
5. ✅ Routes requests to AgentCore backend with proper authentication
6. ✅ Supports all AgentCore protocols (HTTP, WebSocket, MCP)

## AgentCore Endpoints

The gateway proxies the following AgentCore endpoints:

| Endpoint | Method | Protocol | Purpose |
|----------|--------|----------|---------|
| `/ping` | GET | HTTP | Health check - verify AgentCore is running |
| `/invocations` | POST | HTTP | Agent interactions and task execution |
| `/ws/**` | - | WebSocket | Real-time bidirectional streaming |
| `/mcp/**` | Various | HTTP | Model Context Protocol endpoints |

## Configuration

### Application Configuration (application.yml)

```yaml
# AgentCore backend configuration
agentcore:
  # AgentCore HTTP endpoint URL (for /ping, /invocations)
  endpoint: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com

  # AgentCore WebSocket endpoint URL (for /ws/**)
  endpoint.ws: wss://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com

  # AgentCore MCP endpoint URL (for /mcp/**)
  endpoint.mcp: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com

  # Gateway's public URL (used as JWT issuer)
  issuer: https://agentid.ellin.net

  # JWT audience (AgentCore validates this)
  audience: agentcore-gateway

# Spring Cloud Gateway routes
spring:
  cloud:
    gateway:
      routes:
        # AgentCore ping endpoint (health check)
        - id: agentcore-ping
          uri: ${agentcore.endpoint}
          predicates:
            - Path=/ping

        # AgentCore invocations endpoint (main agent interactions)
        - id: agentcore-invocations
          uri: ${agentcore.endpoint}
          predicates:
            - Path=/invocations

        # AgentCore WebSocket endpoint (real-time streaming)
        - id: agentcore-websocket
          uri: ${agentcore.endpoint.ws}
          predicates:
            - Path=/ws/**

        # Model Context Protocol (MCP) endpoint
        - id: agentcore-mcp
          uri: ${agentcore.endpoint.mcp}
          predicates:
            - Path=/mcp/**
```

### AgentCore Configuration in AWS

AgentCore must be configured to trust JWTs from the gateway:

1. **OIDC Issuer URL**: `https://agentid.ellin.net` (matches `agentcore.issuer`)
2. **JWKS URI**: `https://agentid.ellin.net/.well-known/jwks.json` (auto-discovered)
3. **Audience**: `agentcore-gateway` (matches `agentcore.audience`)

AgentCore will:
- Fetch OIDC configuration from `https://agentid.ellin.net/.well-known/openid-configuration`
- Fetch public keys from `https://agentid.ellin.net/.well-known/jwks.json`
- Validate JWT signature using RS256 algorithm
- Validate issuer (`iss`) matches expected issuer
- Validate audience (`aud`) contains expected audience
- Extract `username` or `user_name` claim for user identity

## JWT Transformation

### Incoming Teleport JWT

Teleport sends JWTs in the `X-Teleport-Jwt-Assertion` header (or `teleport-jwt-assertion` after ingress lowercasing):

```json
{
  "iss": "https://ellinj.teleport.sh",
  "sub": "jeffrey.ellin@goteleport.com",
  "username": "jeffrey.ellin@goteleport.com",
  "roles": ["admin", "access", "editor", "mcp-user"],
  "exp": 1735142400,
  "iat": 1735138800
}
```

**Important**: Teleport uses `username` claim (not `user_name`).

### Outgoing Gateway JWT

The gateway mints new JWTs signed with its own key and sends them to AgentCore in the `Authorization: Bearer` header:

```json
{
  "iss": "https://agentid.ellin.net",
  "sub": "jeffrey.ellin@goteleport.com",
  "aud": ["agentcore-gateway"],
  "username": "jeffrey.ellin@goteleport.com",
  "user_name": "jeffrey.ellin@goteleport.com",
  "scope": "mcp:invoke mcp:tools",
  "auth_source": "teleport",
  "teleport_roles": ["admin", "access", "editor", "mcp-user"],
  "exp": 1735146000,
  "iat": 1735142400
}
```

**Claims Mapping**:

| Teleport JWT | Gateway JWT | Purpose |
|--------------|-------------|---------|
| `username` | `sub` | User identity (subject) |
| `username` | `username` | Explicit username claim |
| `username` | `user_name` | Alternative format for compatibility |
| `roles` | `teleport_roles` | Original Teleport roles preserved |
| - | `iss` | Gateway issuer URL |
| - | `aud` | AgentCore audience |
| - | `scope` | MCP permissions |
| - | `auth_source` | Provenance tracking |

## Request Flow

```
┌──────────┐       ┌─────────────┐       ┌────────────┐       ┌─────────────┐
│          │       │  Teleport   │       │   Spring   │       │  AgentCore  │
│  Client  │──────►│     App     │──────►│   Cloud    │──────►│   Gateway   │
│          │ mTLS  │   Service   │  JWT  │  Gateway   │  JWT  │             │
└──────────┘       └─────────────┘       └────────────┘       └─────────────┘
                         │                      │                     │
                         │                      │                     │
                    Adds JWT in            Validates JWT         Validates JWT
                 X-Teleport-Jwt-         Mints new JWT         using JWKS from
                  Assertion header       Signed by Gateway      gateway issuer
```

### Filter Chain

The gateway processes requests through these filters:

1. **TeleportToAgentCoreTokenFilter** (order -10):
   - Checks for `X-Teleport-Jwt-Assertion` or `teleport-jwt-assertion` header
   - Decodes and validates Teleport JWT
   - Extracts `username` claim
   - Mints new AgentCore JWT with gateway signature
   - Replaces headers: removes Teleport headers, adds `Authorization: Bearer <new-jwt>`

2. **RequestResponseLoggingFilter** (order -5):
   - Logs client → gateway requests
   - Logs gateway → client responses

3. **HostHeaderFilter** (order 10001):
   - Updates `Host` header to match target backend

4. **AgentCoreLoggingFilter** (order 10002):
   - Logs gateway → AgentCore requests
   - Logs AgentCore → gateway responses

## Testing

### Prerequisites

```bash
# Login to Teleport
tsh login --proxy=ellinj.teleport.sh

# Login to the app
tsh app login agentid
```

### Test Ping Endpoint

```bash
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/ping
```

Expected response:
```json
{
  "status": "healthy",
  "timestamp": "2024-12-26T12:00:00Z"
}
```

### Test Invocations Endpoint

```bash
curl -X POST \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  -H "Content-Type: application/json" \
  -d '{"action":"invoke","parameters":{"message":"Hello"}}' \
  https://agentid.ellinj.teleport.sh/invocations | jq .
```

### Test MCP Endpoint

```bash
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/mcp/tools | jq .
```

### Test WebSocket Endpoint

```bash
# Using wscat (npm install -g wscat)
tsh app login agentid
wscat -c "wss://agentid.ellinj.teleport.sh/ws" \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key
```

### Verify JWT Transformation

The `/test/echo` endpoint shows the JWT transformation process:

```bash
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo | jq .
```

Response shows:
- Source of JWT (Teleport-Jwt-Assertion or Authorization)
- Full JWT token
- Decoded payload with claims
- Request path and method

## OIDC Discovery and JWKS

AgentCore validates JWTs by fetching the gateway's public keys.

### OIDC Discovery Endpoint

```bash
curl https://agentid.ellin.net/.well-known/openid-configuration | jq .
```

Response:
```json
{
  "issuer": "https://agentid.ellin.net",
  "jwks_uri": "https://agentid.ellin.net/.well-known/jwks.json",
  "id_token_signing_alg_values_supported": ["RS256"],
  "subject_types_supported": ["public"]
}
```

**Note**: This is NOT an OAuth2 authorization server. The gateway mints JWTs internally and sends them directly to AgentCore. AgentCore only needs to validate JWT signatures and claims, not request tokens.

### JWKS Endpoint

```bash
curl https://agentid.ellin.net/.well-known/jwks.json | jq .
```

Response:
```json
{
  "keys": [
    {
      "kty": "RSA",
      "e": "AQAB",
      "use": "sig",
      "kid": "gateway-key-2024",
      "alg": "RS256",
      "n": "xGOr-H0A-6..."
    }
  ]
}
```

AgentCore uses this to:
1. Fetch the public key matching the `kid` in the JWT header
2. Verify the JWT signature using RS256 algorithm
3. Validate claims (`iss`, `aud`, `exp`)

## Logging and Debugging

The gateway provides comprehensive logging for all requests:

### Gateway Logs

```bash
# Local development
./mvnw spring-boot:run

# Kubernetes
kubectl logs -l app=spring-gateway -f
```

Log output shows:

1. **Incoming Request** (RequestResponseLoggingFilter):
   - Method, URI, path
   - All headers including `X-Teleport-Jwt-Assertion` or `teleport-jwt-assertion`
   - Full JWT token

2. **JWT Transformation** (TeleportToAgentCoreTokenFilter):
   - Teleport JWT validation result
   - Extracted username and roles
   - Minted AgentCore JWT

3. **Outbound Request to AgentCore** (AgentCoreLoggingFilter):
   - Target URI
   - Updated Host header
   - Authorization header with new JWT

4. **Response from AgentCore** (AgentCoreLoggingFilter):
   - Status code
   - Duration
   - Response headers

### Example Log Sequence

```
=== Incoming Request ===
Method: POST
URI: https://agentid.ellin.net/invocations
Path: /invocations
Headers:
  teleport-jwt-assertion: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
  host: agentid.ellin.net

=== JWT Transformation ===
JWT source: teleport-jwt-assertion
Teleport JWT decoded successfully. Claims: [username, roles, sub, iss, exp, iat]
Extracted username: jeffrey.ellin@goteleport.com
Extracted roles: [admin, access, editor, mcp-user]
Minted AgentCore JWT with username: jeffrey.ellin@goteleport.com

=== Outbound Request to AgentCore ===
Method: POST
Target URI: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com/invocations
Path: /invocations
Headers:
  host: your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
  authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...

=== Response from AgentCore ===
Status Code: 200 OK
Duration: 245ms
```

## Troubleshooting

### AgentCore returns 401 Unauthorized

**Possible causes**:

1. **AgentCore not configured with correct OIDC issuer**:
   - Verify AgentCore is configured with issuer: `https://agentid.ellin.net`
   - Check OIDC discovery is accessible from AgentCore's network

2. **JWKS endpoint not accessible**:
   ```bash
   # Verify JWKS is publicly accessible
   curl https://agentid.ellin.net/.well-known/jwks.json
   ```

3. **Clock skew**:
   - JWT has `iat` (issued at) and `exp` (expires at) claims
   - Verify system clocks are synchronized (use NTP)

4. **Wrong audience**:
   - Verify `agentcore.audience` in application.yml matches AgentCore configuration
   - Check logs for minted JWT's `aud` claim

5. **Signature validation failure**:
   - Verify gateway's JWKS endpoint returns valid public keys
   - Check JWT header has correct `kid` (key ID)

### AgentCore returns 403 Forbidden

**Possible causes**:

1. **Missing or invalid scope**:
   - Verify minted JWT has `scope: "mcp:invoke mcp:tools"`
   - Check AgentCore's authorization requirements

2. **Missing username claim**:
   - Verify minted JWT has both `username` and `user_name` claims
   - Check AgentCore logs for which claim it expects

### No JWT in logs

**Possible causes**:

1. **Wrong header name**:
   - Ingress controllers may lowercase headers
   - Gateway checks both `X-Teleport-Jwt-Assertion` and `teleport-jwt-assertion`

2. **Teleport not configured**:
   - Verify Teleport app service is running
   - Check Teleport app configuration includes the app name

3. **Request not reaching gateway**:
   - Check Kubernetes ingress is routing to correct service
   - Verify DNS resolves to correct IP

### Host header not updated

The `HostHeaderFilter` should update the Host header to match the backend. If you see:

```
Outbound Request to AgentCore:
  host: agentid.ellin.net
```

But target URI is `https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com`, then:

1. **Check filter order**:
   - HostHeaderFilter should be at order 10001
   - Must run after RouteToRequestUrlFilter (10000)

2. **Check gatewayRequestUrl attribute**:
   - Filter uses `org.springframework.cloud.gateway.support.ServerWebExchangeUtils.gatewayRequestUrl`
   - Verify route configuration sets this correctly

### Decode JWT for debugging

```bash
# Decode Teleport JWT
tsh app login agentid
tsh app config agentid | grep -o 'X-Teleport-Jwt-Assertion:.*' | \
  cut -d: -f2 | xargs | cut -d. -f2 | base64 -d | jq .

# Decode gateway JWT from logs
echo "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..." | cut -d. -f2 | base64 -d | jq .
```

## Security Considerations

1. ✅ **Short-Lived Tokens**: Minted JWTs expire in 1 hour
2. ✅ **Signature Validation**: Both Teleport and gateway JWTs are validated
3. ✅ **HTTPS Only**: All communication over TLS
4. ✅ **Audience Validation**: AgentCore validates `aud` claim
5. ✅ **User Identity Preserved**: Audit logs show actual user, not service account
6. ⚠️ **Key Rotation**: Implement periodic key rotation for production
7. ⚠️ **Shared Keys**: Use Kubernetes secrets for multi-pod deployments

## Production Checklist

Before deploying to production:

- [ ] Enable Teleport JWT validation: `teleport.validation.enabled: true`
- [ ] Configure AgentCore with correct OIDC issuer URL
- [ ] Verify JWKS endpoint is publicly accessible from AgentCore's network
- [ ] Set up monitoring for JWT validation failures
- [ ] Implement key rotation strategy
- [ ] Configure proper logging retention
- [ ] Set up alerts for 401/403 responses from AgentCore
- [ ] Test all endpoints (ping, invocations, ws, mcp)
- [ ] Verify user identity appears in AgentCore logs
- [ ] Test JWT expiration and renewal

## References

- [AWS Bedrock AgentCore Documentation](https://docs.aws.amazon.com/bedrock/)
- [Spring Cloud Gateway JWT Authentication](https://spring.io/guides/gs/gateway/)
- [OAuth2 JWT Bearer Tokens](https://tools.ietf.org/html/rfc6750)
- [OIDC Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html)
- [JWKS (JSON Web Key Set)](https://tools.ietf.org/html/rfc7517)
