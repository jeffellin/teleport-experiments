# Teleport to AgentCore Gateway: Identity-Preserving Authentication

## Overview

This document describes an architecture pattern for integrating **Teleport** identity with **AWS Bedrock AgentCore Gateway**, using **Spring Cloud Gateway** as an identity translation layer. The approach preserves user identity end-to-end, enabling audit trails and per-user authorization when invoking AI agent tools.

## Problem Statement

AgentCore Gateway requires OAuth 2.0 Bearer tokens from a trusted issuer. Teleport provides strong identity through its own JWT tokens, but AgentCore cannot be configured to trust Teleport directly as an OAuth provider. We need a way to:

1. Authenticate users via Teleport (SSO, MFA, short-lived credentials)
2. Translate Teleport identity into tokens AgentCore trusts
3. Preserve user identity (`user_name`) through to tool execution
4. Maintain audit trails showing which user invoked which tools

## Architecture


*[View full diagram]( https://jeffellin.github.io/teleport-experiments//teleport-agent-core-spring/identity-flow-diagram.html)*

### Component Responsibilities

| Component | Role |
|-----------|------|
| **Teleport Auth** | Authenticates users via SSO/MFA, issues short-lived JWTs |
| **Teleport Proxy** | Runs in AWS, forwards requests with JWT in Authorization header |
| **Spring Cloud Gateway** | Validates Teleport JWT, mints new JWT for AgentCore |
| **AgentCore Gateway** | Validates Spring JWT, executes MCP tools with user context |

### Trust Chain

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Teleport Auth  │         │ Spring Gateway  │         │    AgentCore    │
│                 │         │                 │         │                 │
│  JWKS: /jwks    │◄────────│  Fetches JWKS   │         │                 │
│                 │         │  to validate    │         │                 │
│                 │         │                 │         │                 │
│                 │         │  JWKS: /.well-  │────────►│  Fetches JWKS   │
│                 │         │  known/jwks.json│         │  to validate    │
└─────────────────┘         └─────────────────┘         └─────────────────┘
```

## Implementation

### Project Dependencies

```xml
<dependencies>
    <!-- Spring Cloud Gateway -->
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-gateway</artifactId>
    </dependency>
    
    <!-- OAuth2 Authorization Server (for minting JWTs) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-authorization-server</artifactId>
    </dependency>
    
    <!-- OAuth2 Resource Server (for validating Teleport JWTs) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
    </dependency>
</dependencies>
```

### Configuration

```yaml
server:
  port: 8080

spring:
  cloud:
    gateway:
      routes:
        - id: agentcore
          uri: https://gateway.bedrock-agentcore.us-east-1.amazonaws.com
          predicates:
            - Path=/mcp/**

teleport:
  jwks-uri: https://teleport.example.com/webapi/jwks

agentcore:
  issuer: https://your-gateway.example.com
  audience: agentcore-gateway
```

### Token Minting Service

The `AgentCoreTokenMinter` creates JWTs signed with your private key, preserving the user identity from Teleport:

```java
@Service
public class AgentCoreTokenMinter {

    private final JwtEncoder jwtEncoder;

    public AgentCoreTokenMinter(JWKSource<SecurityContext> jwkSource) {
        this.jwtEncoder = new NimbusJwtEncoder(jwkSource);
    }

    public String mintToken(String teleportUsername, Map<String, Object> additionalClaims) {
        Instant now = Instant.now();
        
        JwtClaimsSet claims = JwtClaimsSet.builder()
            .issuer("https://your-gateway.example.com")
            .issuedAt(now)
            .expiresAt(now.plus(1, ChronoUnit.HOURS))
            .subject(teleportUsername)                          // Identity preserved
            .audience(List.of("agentcore-gateway"))
            .claim("scope", "mcp:invoke mcp:tools")
            .claim("username", teleportUsername)                // Explicit claim
            .claim("auth_source", "teleport")                   // Provenance
            .claims(c -> c.putAll(additionalClaims))
            .build();

        JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).build();
        
        return jwtEncoder.encode(JwtEncoderParameters.from(header, claims))
            .getTokenValue();
    }
}
```

### Gateway Filter

The filter intercepts requests, validates the Teleport JWT, and swaps it for a newly minted token:

```java
@Component
public class TeleportToAgentCoreTokenFilter implements GlobalFilter, Ordered {

    private final AgentCoreTokenMinter tokenMinter;
    private final NimbusJwtDecoder teleportJwtDecoder;

    public TeleportToAgentCoreTokenFilter(
            AgentCoreTokenMinter tokenMinter,
            @Value("${teleport.jwks-uri}") String teleportJwksUri) {
        this.tokenMinter = tokenMinter;
        this.teleportJwtDecoder = NimbusJwtDecoder.withJwkSetUri(teleportJwksUri).build();
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String authHeader = exchange.getRequest()
            .getHeaders()
            .getFirst(HttpHeaders.AUTHORIZATION);

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            return chain.filter(exchange);
        }

        String teleportToken = authHeader.substring(7);

        return Mono.fromCallable(() -> {
                // Validate Teleport JWT
                Jwt teleportJwt = teleportJwtDecoder.decode(teleportToken);
                
                // Extract user_name claim
                String username = teleportJwt.getClaimAsString("user_name");
                if (username == null) {
                    throw new IllegalArgumentException("Missing user_name claim");
                }

                // Carry forward additional claims
                Map<String, Object> additionalClaims = new HashMap<>();
                if (teleportJwt.getClaimAsStringList("roles") != null) {
                    additionalClaims.put("teleport_roles", 
                        teleportJwt.getClaimAsStringList("roles"));
                }

                // Mint new token
                return tokenMinter.mintToken(username, additionalClaims);
            })
            .subscribeOn(Schedulers.boundedElastic())
            .flatMap(agentCoreToken -> {
                ServerHttpRequest mutatedRequest = exchange.getRequest()
                    .mutate()
                    .headers(h -> h.setBearerAuth(agentCoreToken))
                    .build();
                
                return chain.filter(exchange.mutate().request(mutatedRequest).build());
            })
            .onErrorResume(e -> {
                exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
                return exchange.getResponse().setComplete();
            });
    }

    @Override
    public int getOrder() {
        return -10;
    }
}
```

### Authorization Server Configuration

Configure Spring Authorization Server to expose JWKS for AgentCore to validate tokens:

```java
@Configuration
public class AuthServerConfig {

    @Bean
    public JWKSource<SecurityContext> jwkSource() {
        KeyPair keyPair = generateRsaKey();
        RSAPublicKey publicKey = (RSAPublicKey) keyPair.getPublic();
        RSAPrivateKey privateKey = (RSAPrivateKey) keyPair.getPrivate();
        
        RSAKey rsaKey = new RSAKey.Builder(publicKey)
            .privateKey(privateKey)
            .keyID(UUID.randomUUID().toString())
            .build();
        
        JWKSet jwkSet = new JWKSet(rsaKey);
        return new ImmutableJWKSet<>(jwkSet);
    }

    @Bean
    public AuthorizationServerSettings authorizationServerSettings() {
        return AuthorizationServerSettings.builder()
            .issuer("https://your-gateway.example.com")
            .build();
    }

    private static KeyPair generateRsaKey() {
        try {
            KeyPairGenerator keyPairGenerator = KeyPairGenerator.getInstance("RSA");
            keyPairGenerator.initialize(2048);
            return keyPairGenerator.generateKeyPair();
        } catch (Exception ex) {
            throw new IllegalStateException(ex);
        }
    }
}
```

### Configure AgentCore to Trust Your Gateway

When creating the AgentCore Gateway, specify your Spring Gateway as the trusted OAuth provider:

```bash
aws bedrock-agentcore create-gateway \
  --name my-gateway \
  --authorization-configuration '{
    "oauth2ProviderConfiguration": {
      "issuerUrl": "https://your-gateway.example.com",
      "allowedClients": ["mcp-client"],
      "allowedAudiences": ["agentcore-gateway"]
    }
  }'
```

## Token Flow

### Incoming Teleport JWT

```json
{
  "iss": "teleport.example.com",
  "sub": "jeff@example.com",
  "user_name": "jeff",
  "roles": ["developer", "mcp-user"],
  "exp": 1735142400
}
```

### Outgoing Gateway JWT

```json
{
  "iss": "your-gateway.example.com",
  "sub": "jeff",
  "username": "jeff",
  "aud": ["agentcore-gateway"],
  "scope": "mcp:invoke mcp:tools",
  "auth_source": "teleport",
  "teleport_roles": ["developer", "mcp-user"],
  "exp": 1735146000
}
```

## Identity Preservation

The key insight is that the `user_name` claim from Teleport becomes the `sub` (subject) claim in the minted token. This means:

1. **Audit Logs**: AgentCore logs show "jeff" made the request, not a service account
2. **Per-User Authorization**: MCP tools can check the `username` claim for fine-grained access control
3. **Provenance**: The `auth_source` claim indicates the original identity provider
4. **Role Propagation**: Teleport roles can inform tool-level authorization decisions

```
Teleport JWT              Gateway JWT              AgentCore
─────────────────────────────────────────────────────────────
user_name: "jeff"    →    sub: "jeff"         →   Logged as "jeff"
                          username: "jeff"    →   Available to tools
roles: [...]         →    teleport_roles: [...] → Authorization decisions
```

## Endpoints Exposed by Spring Gateway

| Endpoint | Purpose |
|----------|---------|
| `/.well-known/openid-configuration` | OIDC Discovery (AgentCore fetches this) |
| `/.well-known/jwks.json` | JWKS endpoint (AgentCore validates tokens) |
| `/mcp/**` | Proxied to AgentCore Gateway |

## Security Considerations

1. **Short-Lived Tokens**: Both Teleport and minted tokens should have short expiration times
2. **Key Rotation**: Implement key rotation for your signing keys
3. **HTTPS Only**: All communication should be over TLS
4. **Audience Validation**: AgentCore validates the `aud` claim matches expected value
5. **Clock Skew**: Allow for reasonable clock skew in token validation

## Testing

### Verify JWKS Endpoint

```bash
curl https://your-gateway.example.com/.well-known/jwks.json
```

### Test Token Flow

```bash
# Get Teleport JWT
tsh login
export TELEPORT_TOKEN=$(tsh credentials show --format=json | jq -r '.jwt')

# Call through gateway
curl -H "Authorization: Bearer $TELEPORT_TOKEN" \
  https://your-gateway.example.com/mcp/tools/list
```

## References

- [AWS Bedrock AgentCore Gateway Documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html)
- [Teleport Workload Identity](https://goteleport.com/docs/machine-id/workload-identity/)
- [Spring Cloud Gateway](https://spring.io/projects/spring-cloud-gateway)
- [Spring Authorization Server](https://spring.io/projects/spring-authorization-server)
- [MCP Specification](https://modelcontextprotocol.io/)
