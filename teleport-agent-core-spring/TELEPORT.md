# Running with Teleport App Access

This guide shows how to run the Spring Gateway locally and expose it through Teleport at `agentid.ellin.net`.

## Prerequisites

- Teleport account at `ellinj.teleport.sh`
- `tsh` CLI installed
- App service join token from Teleport

## Setup

### 1. Get a Join Token

Create an app join token in Teleport:

```bash
# Login to Teleport
tsh login --proxy=ellinj.teleport.sh

# Create a join token for app service (do this in Teleport Web UI or via tctl)
# Or use the Teleport web UI: Access Management > Join Tokens > Add Token
```

Or if you have admin access:

```bash
tctl tokens add --type=app --ttl=1h
```

### 2. Update teleport.yml

Edit `teleport.yml` and update:

```yaml
teleport:
  auth_token: "your-join-token-here"  # Add your token
```

Or you can pass the token via command line (see below).

### 3. Start the Spring Gateway

```bash
# Start the Spring app locally
./mvnw spring-boot:run
```

The app will run on `http://localhost:8080`.

### 4. Start Teleport App Service

In another terminal:

```bash
# Using the helper script (easiest)
./start-with-teleport.sh your-join-token-here

# Or using Make
make teleport-start TOKEN=your-join-token-here

# Or manually with full command
mkdir -p ./teleport-data
TELEPORT_DATA_DIR=$(pwd)/teleport-data teleport app start \
  --token=your-join-token-here \
  --auth-server=ellinj.teleport.sh:443 \
  --name=agentid \
  --uri=https://agentid.ellin.net \
  --labels=env=dev,app=spring-gateway \
  --debug
```

### 5. Access the App

Users can now access the app through Teleport:

```bash
# Login to Teleport
tsh login --proxy=ellinj.teleport.sh

# Access the app (opens in browser with automatic JWT)
tsh app login agentid

# Or get app info
tsh app ls

# Make requests with automatic JWT injection
curl $(tsh app config --format=uri agentid)/actuator/health

# Or use the app URL directly
curl https://agentid.ellin.net/actuator/health
```

## How It Works

1. **Teleport App Service** runs locally and proxies `localhost:8080`
2. **Users authenticate** to Teleport and get a session
3. **Teleport injects JWT** into requests to your app
4. **Spring Gateway** receives the Teleport JWT and:
   - Validates it (if `teleport.validation.enabled=true`)
   - Extracts `user_name` and `roles` claims
   - Mints a new AgentCore JWT
   - Forwards to AgentCore

## JWT Flow

```
User → Teleport (auth) → App Service (proxy) → Spring Gateway (localhost:8080)
                            ↓ (injects Teleport JWT)
Spring Gateway extracts user_name → mints AgentCore JWT → forwards to AgentCore
```

## Testing

### Test Locally Without Teleport

```bash
# Create a test JWT
export JWT="eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJ1c2VyX25hbWUiOiJ0ZXN0LXVzZXJAZXhhbXBsZS5jb20iLCJyb2xlcyI6WyJkZXZlbG9wZXIiXSwic3ViIjoidGVzdC11c2VyQGV4YW1wbGUuY29tIiwiaWF0IjoxNzAzNzg0MDAwLCJleHAiOjk5OTk5OTk5OTl9."

# Test directly
curl -H "Authorization: Bearer $JWT" http://localhost:8080/test/echo
```

### Test Through Teleport

```bash
# Login and get app JWT
tsh app login agentid
export TELEPORT_JWT=$(tsh app config --format=json agentid | jq -r '.jwt')

# Test with Teleport JWT
curl -H "Authorization: Bearer $TELEPORT_JWT" http://localhost:8080/test/echo

# Check what's in the JWT
echo $TELEPORT_JWT | cut -d'.' -f2 | base64 -d | jq .
```

## Configuration

### Application Settings (application.yml)

For local development with Teleport:

```yaml
teleport:
  # Your Teleport JWKS endpoint
  jwks-uri: "https://ellinj.teleport.sh/.well-known/jwks.json"

  # Enable validation for production, disable for quick testing
  validation:
    enabled: true

agentcore:
  # Use localhost for local testing, or the public URL
  issuer: "https://agentid.ellin.net"
  audience: "agentcore-gateway"
```

### Teleport App Service (teleport.yml)

The `teleport.yml` file configures:
- **Proxy server**: `ellinj.teleport.sh:443`
- **App URI**: `http://localhost:8080` (your local Spring app)
- **Public address**: `agentid.ellin.net`

## Troubleshooting

### App not showing in Teleport

```bash
# Check app service logs
teleport app start --config=teleport.yml --debug

# Verify the app is registered
tsh app ls
```

### JWT validation fails

Check that the JWKS URI matches your Teleport cluster:

```bash
# Test JWKS endpoint
curl https://ellinj.teleport.sh/.well-known/jwks.json

# Update in application.yml
teleport:
  jwks-uri: "https://ellinj.teleport.sh/.well-known/jwks.json"
```

### Can't connect to localhost:8080

Make sure your Spring app is running:

```bash
# Check if app is running
curl http://localhost:8080/actuator/health

# Start the app
./mvnw spring-boot:run
```

## Production Deployment

For production, deploy to Kubernetes instead of running locally:

```bash
# Build and push image
make docker-push REGISTRY=your-registry.com

# Deploy to Kubernetes
kubectl apply -k k8s/

# The app will be available at https://agentid.ellin.net
# Teleport routes traffic directly to the Kubernetes ingress
```

## References

- [Teleport Application Access](https://goteleport.com/docs/application-access/)
- [Teleport App Service Configuration](https://goteleport.com/docs/reference/config/#app-service)
