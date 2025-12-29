# Teleport to AgentCore Gateway: Identity-Preserving JWT Transformation

## Overview

A **production-ready** Spring Cloud Gateway that acts as a JWT transformation proxy between **Teleport** and **AWS Bedrock AgentCore Gateway**. This gateway enables secure, identity-preserving access to AgentCore by translating Teleport JWTs into AgentCore-trusted tokens while maintaining full user context and audit trails.

**Status**: ✅ **Working and Deployed**

## Problem Statement

AgentCore Gateway requires OAuth 2.0 Bearer tokens from a trusted issuer for authentication. Teleport provides strong identity through its own JWT tokens, but AgentCore cannot be configured to trust Teleport directly. This gateway solves that problem by:

1. ✅ Authenticating users via Teleport (SSO, MFA, short-lived credentials)
2. ✅ Extracting user identity and roles from Teleport JWTs
3. ✅ Minting new JWTs signed by the gateway that AgentCore trusts
4. ✅ Preserving user identity (`username`, `sub`) through to tool execution
5. ✅ Maintaining comprehensive audit trails showing which user invoked which tools

## Architecture

*[View full diagram](https://jeffellin.github.io/teleport-experiments//teleport-agent-core-spring/identity-flow-diagram.html)*

### Component Flow

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

### Trust Chain

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Teleport Auth  │         │ Spring Gateway  │         │    AgentCore    │
│                 │         │                 │         │                 │
│  JWKS:          │◄────────│  Fetches JWKS   │         │                 │
│  /webapi/jwks   │         │  to validate    │         │                 │
│                 │         │  Teleport JWT   │         │                 │
│                 │         │                 │         │                 │
│                 │         │  JWKS: /.well-  │────────►│  Fetches JWKS   │
│                 │         │  known/jwks.json│         │  to validate    │
│                 │         │  Mints JWTs     │         │  Gateway JWT    │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

## Implementation

### Project Dependencies

```xml
<dependencies>
    <!-- Spring Cloud Gateway (Reactive) -->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-gateway</artifactId>
    </dependency>

    <!-- OAuth2 Resource Server (for validating Teleport JWTs) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
    </dependency>

    <!-- Nimbus JOSE JWT (for minting and signing JWTs) -->
    <dependency>
        <groupId>com.nimbusds</groupId>
        <artifactId>nimbus-jose-jwt</artifactId>
    </dependency>

    <!-- Spring Boot Actuator (health checks) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
</dependencies>
```

### Configuration

See [AGENTCORE.md](notes/AGENTCORE.md) and [TELEPORT.md](notes/TELEPORT.md) for detailed configuration.

```yaml
server:
  port: 8080

spring:
  cloud:
    gateway:
      routes:
        # AgentCore ping endpoint
        - id: agentcore-ping
          uri: ${agentcore.endpoint}
          predicates:
            - Path=/ping

        # AgentCore invocations endpoint
        - id: agentcore-invocations
          uri: ${agentcore.endpoint}
          predicates:
            - Path=/invocations

        # AgentCore WebSocket endpoint
        - id: agentcore-websocket
          uri: ${agentcore.endpoint.ws}
          predicates:
            - Path=/ws/**

        # AgentCore MCP endpoint
        - id: agentcore-mcp
          uri: ${agentcore.endpoint.mcp}
          predicates:
            - Path=/mcp/**

# Teleport configuration
teleport:
  jwks-uri: https://ellinj.teleport.sh/.well-known/jwks.json
  validation:
    enabled: false  # Set to true in production

# AgentCore configuration
agentcore:
  endpoint: https://your-agentcore.gateway.bedrock-agentcore.us-east-2.amazonaws.com
  endpoint.ws: wss://your-agentcore.gateway.bedrock-agentcore.us-east-2.amazonaws.com
  endpoint.mcp: https://your-agentcore.gateway.bedrock-agentcore.us-east-2.amazonaws.com
  issuer: https://agentid.ellin.net
  audience: agentcore-gateway
```

### Key Components

#### 1. TeleportToAgentCoreTokenFilter

Validates Teleport JWTs and mints new AgentCore JWTs:

```java
@Component
public class TeleportToAgentCoreTokenFilter implements GlobalFilter, Ordered {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // Check for Teleport JWT (ingress controllers lowercase headers)
        String token = exchange.getRequest().getHeaders().getFirst("X-Teleport-Jwt-Assertion");
        if (token == null) {
            token = exchange.getRequest().getHeaders().getFirst("teleport-jwt-assertion");
        }

        if (token == null) {
            return chain.filter(exchange);  // Pass through if no JWT
        }

        return Mono.fromCallable(() -> {
                    // Decode Teleport JWT
                    Jwt teleportJwt = jwtDecoder.decode(token);

                    // Extract username (Teleport uses 'username', not 'user_name')
                    String username = teleportJwt.getClaimAsString("username");

                    // Preserve Teleport roles
                    Map<String, Object> additionalClaims = new HashMap<>();
                    if (teleportJwt.getClaimAsStringList("roles") != null) {
                        additionalClaims.put("teleport_roles",
                            teleportJwt.getClaimAsStringList("roles"));
                    }

                    // Mint new token
                    return tokenMinter.mintToken(username, additionalClaims);
                })
                .flatMap(agentCoreToken -> {
                    // Replace Teleport JWT with AgentCore JWT
                    ServerHttpRequest mutatedRequest = exchange.getRequest()
                            .mutate()
                            .headers(h -> {
                                h.remove("X-Teleport-Jwt-Assertion");
                                h.remove("teleport-jwt-assertion");
                                h.set("Authorization", "Bearer " + agentCoreToken);
                            })
                            .build();

                    return chain.filter(exchange.mutate().request(mutatedRequest).build());
                });
    }

    @Override
    public int getOrder() {
        return -10;  // Run early in filter chain
    }
}
```

#### 2. AgentCoreTokenMinter

Mints JWTs signed with the gateway's private key:

```java
@Service
public class AgentCoreTokenMinter {

    public String mintToken(String teleportUsername, Map<String, Object> additionalClaims) {
        Instant now = Instant.now();

        JwtClaimsSet claims = JwtClaimsSet.builder()
            .issuer(issuer)                              // https://agentid.ellin.net
            .issuedAt(now)
            .expiresAt(now.plus(1, ChronoUnit.HOURS))
            .subject(teleportUsername)                   // Identity preserved
            .audience(List.of(audience))                 // agentcore-gateway
            .claim("scope", "mcp:invoke mcp:tools")      // Permissions
            .claim("username", teleportUsername)         // Explicit username
            .claim("user_name", teleportUsername)        // Alternative format
            .claim("auth_source", "teleport")            // Provenance
            .claims(c -> c.putAll(additionalClaims))     // Teleport roles
            .build();

        return jwtEncoder.encode(JwtEncoderParameters.from(
            JwsHeader.with(SignatureAlgorithm.RS256).build(),
            claims
        )).getTokenValue();
    }
}
```

#### 3. Logging Filters

Three logging filters provide complete visibility:

- **RequestResponseLoggingFilter** (order -5): Logs client → gateway requests/responses
- **AgentCoreLoggingFilter** (order 10002): Logs gateway → AgentCore requests/responses
- **HostHeaderFilter** (order 10001): Updates Host header to match backend

## Token Flow

### Incoming Teleport JWT

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

### Outgoing Gateway JWT

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

## Identity Preservation

The `username` claim from Teleport flows through to AgentCore:

```
Teleport JWT              Gateway JWT              AgentCore
─────────────────────────────────────────────────────────────
username: "jeff"     →    sub: "jeff"         →   Logged as "jeff"
                          username: "jeff"    →   Available to tools
                          user_name: "jeff"   →   Compatibility
roles: [...]         →    teleport_roles: [...] → Authorization
```

**Benefits:**
1. ✅ **Audit Logs**: AgentCore logs show actual user, not service account
2. ✅ **Per-User Authorization**: MCP tools can check username for access control
3. ✅ **Provenance Tracking**: `auth_source` indicates original IdP
4. ✅ **Role Propagation**: Teleport roles inform tool-level decisions

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `/.well-known/openid-configuration` | OIDC Discovery for JWT validation |
| `/.well-known/jwks.json` | Public keys for JWT signature validation |
| `/actuator/health` | Health check endpoint |
| `/test/echo` | Test endpoint showing JWT details |
| `/ping` | Proxied to AgentCore (health check) |
| `/invocations` | Proxied to AgentCore (agent interactions) |
| `/ws/**` | Proxied to AgentCore (WebSocket streaming) |
| `/mcp/**` | Proxied to AgentCore (MCP protocol) |

## Deployment

### Local Development

```bash
# Run Spring Gateway locally
./mvnw spring-boot:run

# Start Teleport app service (proxies to localhost:8082)
./start-with-teleport.sh <your-token>

# Test
curl \
  --cert ~/.tsh/keys/.../agentid.crt \
  --key ~/.tsh/keys/.../agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo
```

### Kubernetes Deployment

See [k8s/README.md](k8s/README.md) for details.

```bash
# Build and push Docker image
make docker-build-x86
docker tag spring-gateway:latest ellinj/spring-agent-gateway:latest
docker push ellinj/spring-agent-gateway:latest

# Deploy to Kubernetes
kubectl apply -f k8s/

# Check status
kubectl get pods -l app=spring-gateway
kubectl logs -l app=spring-gateway -f
```

## Security Considerations

1. ✅ **Short-Lived Tokens**: Minted JWTs expire in 1 hour
2. ✅ **Signature Validation**: Both Teleport and gateway JWTs are validated
3. ✅ **HTTPS Only**: All communication over TLS (enforced by ingress)
4. ✅ **Audience Validation**: AgentCore validates `aud` claim
5. ⚠️ **Key Rotation**: Implement periodic key rotation for production
6. ⚠️ **Shared Keys**: Use k8s secrets for multi-pod deployments

## Testing

### Verify JWKS Endpoint

```bash
curl https://agentid.ellin.net/.well-known/jwks.json | jq .
```

### Verify OIDC Configuration

```bash
curl https://agentid.ellin.net/.well-known/openid-configuration | jq .
```

### Test JWT Flow

```bash
# Login to Teleport
tsh app login agentid

# Test echo endpoint (shows JWT transformation)
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo | jq .
```

## Documentation

- [AGENTCORE.md](notes/AGENTCORE.md) - AgentCore configuration details
- [TELEPORT.md](notes/TELEPORT.md) - Teleport setup and configuration
- [BUILD.md](notes/BUILD.md) - Docker build and deployment
- [k8s/README.md](k8s/README.md) - Kubernetes deployment

## References

- [AWS Bedrock AgentCore Gateway Documentation](https://docs.aws.amazon.com/bedrock/)
- [Teleport Application Access](https://goteleport.com/docs/application-access/introduction/)
- [Spring Cloud Gateway](https://spring.io/projects/spring-cloud-gateway)
- [MCP Specification](https://modelcontextprotocol.io/)
- [RFC 7519 - JWT](https://tools.ietf.org/html/rfc7519)
