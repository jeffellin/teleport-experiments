# Running with Teleport App Access

This guide shows how to run the Spring Gateway with Teleport App Access for local development and production deployment.

## Prerequisites

- Teleport account at `ellinj.teleport.sh`
- `tsh` and `teleport` CLI tools installed
- App service join token from Teleport

## Local Development Setup

### 1. Get a Join Token

Create an app join token in Teleport:

```bash
# Login to Teleport
tsh login --proxy=ellinj.teleport.sh

# Create a join token (requires admin access)
tctl tokens add --type=app --ttl=1h
```

Save the token for use in step 3.

### 2. Start the Spring Gateway Locally

```bash
# Run on localhost:8082
./mvnw spring-boot:run
```

The app will run on `http://localhost:8082` (configured in `application.yml`).

### 3. Start Teleport App Service

The Teleport app service proxies local requests to your localhost Spring Gateway:

```bash
# Using the helper script (recommended)
./start-with-teleport.sh <your-join-token>

# Or using Make
make teleport-start TOKEN=<your-join-token>

# Or manually
teleport start -c teleport-app.yml --token=<your-join-token>
```

The `teleport-app.yml` configuration:
- Points to `http://localhost:8082` (your local Spring Gateway)
- Registers app as `agentid` in your Teleport cluster
- Makes it available at `https://agentid.ellinj.teleport.sh`

### 4. Access the App Through Teleport

```bash
# Login to Teleport app
tsh app login agentid

# Test the echo endpoint (shows JWT transformation)
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo | jq .
```

## How It Works

### Request Flow

```
┌──────────┐       ┌─────────────┐       ┌────────────┐       ┌─────────────┐
│          │       │  Teleport   │       │   Spring   │       │  AgentCore  │
│  Client  │──────►│     App     │──────►│   Cloud    │──────►│   Gateway   │
│          │ mTLS  │   Service   │  JWT  │  Gateway   │  JWT  │             │
└──────────┘       └─────────────┘       └────────────┘       └─────────────┘
                         │                      │                     │
                    Adds JWT in          Validates JWT            Validates
                 X-Teleport-Jwt-       Mints new JWT              new JWT
                  Assertion header    Signed by Gateway            via JWKS
```

### JWT Header Handling

**Important**: Teleport uses `X-Teleport-Jwt-Assertion` header (not `Authorization: Bearer`):

1. Teleport App Service adds JWT in `X-Teleport-Jwt-Assertion` header
2. Ingress controller (Contour/Envoy) lowercases it to `teleport-jwt-assertion`
3. Spring Gateway checks for both variants
4. Gateway validates JWT, extracts `username` and `roles`
5. Gateway mints new JWT signed with its own key
6. Gateway sends new JWT to AgentCore in `Authorization: Bearer` header

### JWT Claims Mapping

```
Teleport JWT                  Gateway JWT
────────────────────────────────────────────
username: "jeff"         →    sub: "jeff"
                              username: "jeff"
                              user_name: "jeff"
roles: ["admin", ...]    →    teleport_roles: ["admin", ...]
iss: teleport.sh         →    iss: agentid.ellin.net
                              aud: ["agentcore-gateway"]
                              auth_source: "teleport"
```

## Configuration Files

### teleport-app.yml (Local Development)

```yaml
# Teleport App Service Configuration - LOCAL DEVELOPMENT
# Proxies Teleport app "agentid" to local Spring Gateway at http://localhost:8082
# Usage: teleport start -c teleport-app.yml --token=<your-token>
#
version: v3
teleport:
  data_dir: ./teleport-data
  proxy_server: ellinj.teleport.sh:443
  log:
    severity: DEBUG
    output: stderr

app_service:
  enabled: true
  debug_app: true
  apps:
  - name: agentid
    uri: https://agentid.ellin.net
    labels:
      env: dev
      app: spring-gateway
```

### application.yml (Spring Gateway)

```yaml
teleport:
  # Teleport JWKS endpoint for JWT validation
  jwks-uri: https://ellinj.teleport.sh/.well-known/jwks.json

  # Enable validation in production, disable for quick testing
  validation:
    enabled: false  # Set to true for production

agentcore:
  # Gateway's public URL (used as JWT issuer)
  issuer: https://agentid.ellin.net
  audience: agentcore-gateway

  # AgentCore backend endpoints
  endpoint: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
  endpoint.ws: wss://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
  endpoint.mcp: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
```

## Testing

### Test Echo Endpoint

The `/test/echo` endpoint shows JWT transformation details:

```bash
# Login to Teleport app
tsh app login agentid

# Test (shows both incoming Teleport JWT and outgoing gateway JWT)
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo | jq .
```

Response shows:
```json
{
  "jwt_source": "Teleport-Jwt-Assertion",
  "jwt_token": "eyJ...",
  "jwt_payload_decoded": "{\"username\":\"jeffrey.ellin@goteleport.com\",...}",
  "path": "/test/echo",
  "method": "GET"
}
```

### Test Health Endpoint

```bash
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/actuator/health
```

### Verify JWKS Endpoint

```bash
# Public keys for JWT validation (AgentCore fetches this)
curl https://agentid.ellin.net/.well-known/jwks.json | jq .

# OIDC discovery
curl https://agentid.ellin.net/.well-known/openid-configuration | jq .
```

## Logs and Debugging

### Spring Gateway Logs

The gateway has comprehensive logging enabled:

- **RequestResponseLoggingFilter**: Logs all incoming requests and outgoing responses
- **TeleportToAgentCoreTokenFilter**: Logs JWT validation and token minting
- **AgentCoreLoggingFilter**: Logs requests to AgentCore backend
- **HostHeaderFilter**: Updates Host header for backend

```bash
# Watch local logs
./mvnw spring-boot:run

# Or in Kubernetes
kubectl logs -l app=spring-gateway -f
```

### Teleport App Service Logs

```bash
# Start with debug logging
teleport start -c teleport-app.yml --token=<token>  # Already includes --debug

# Logs show:
# - JWT injection into requests
# - Proxy connections
# - mTLS certificate handling
```

## Troubleshooting

### App not showing in Teleport

```bash
# List all apps
tsh app ls

# Should show:
# Application  Description  Type  Public Address
# agentid                   HTTP  agentid.ellinj.teleport.sh
```

If not listed, check Teleport app service logs for errors.

### JWT validation fails

```bash
# Verify Teleport JWKS is accessible
curl https://ellinj.teleport.sh/.well-known/jwks.json | jq .

# Check Spring Gateway logs for validation errors
kubectl logs -l app=spring-gateway | grep "ERROR"
```

### Wrong claim name errors

The gateway looks for `username` (not `user_name`) in Teleport JWTs:

```bash
# Decode your Teleport JWT to verify claims
tsh app login agentid
tsh app config agentid | grep -o 'X-Teleport-Jwt-Assertion:.*' | \
  cut -d: -f2 | xargs | cut -d. -f2 | base64 -d | jq .
```

### Host header issues

The `HostHeaderFilter` updates the Host header to match the backend. Check logs:

```bash
kubectl logs -l app=spring-gateway | grep "host:"

# Should show:
# Incoming: host: agentid.ellin.net
# Outbound: host: your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
```

## Production Deployment

For production, deploy to Kubernetes and point Teleport directly to the K8s ingress:

### Option 1: Direct to K8s (Recommended)

Configure Teleport app in cloud/web UI to point to `https://agentid.ellin.net` (your K8s ingress).

No local Teleport app service needed - Teleport Cloud proxies directly to your K8s deployment.

### Option 2: Run Teleport App Service in K8s

Deploy Teleport app service as a sidecar or separate pod in K8s.

See [k8s/README.md](../k8s/README.md) for Kubernetes deployment details.

## File Reference

| File | Purpose |
|------|---------|
| `teleport-app.yml` | Local dev: proxies to `http://localhost:8082` |
| `start-with-teleport.sh` | Helper script to start Teleport app service |
| `teleport-data/` | Local Teleport data directory (gitignored) |

## References

- [Teleport Application Access](https://goteleport.com/docs/application-access/introduction/)
- [Teleport App Service](https://goteleport.com/docs/application-access/guides/connecting-apps/)
- [Teleport JWT Authentication](https://goteleport.com/docs/application-access/jwt/)
