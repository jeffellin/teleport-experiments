package com.ellin.agentcore.springgateway.filter;

import com.ellin.agentcore.springgateway.service.AgentCoreTokenMinter;
import com.nimbusds.jwt.JWT;
import com.nimbusds.jwt.JWTParser;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

@Component
public class TeleportToAgentCoreTokenFilter implements GlobalFilter, Ordered {

    private static final Logger log = LoggerFactory.getLogger(TeleportToAgentCoreTokenFilter.class);

    private final AgentCoreTokenMinter tokenMinter;
    private final JwtDecoder jwtDecoder;
    private final boolean validationEnabled;

    public TeleportToAgentCoreTokenFilter(
            AgentCoreTokenMinter tokenMinter,
            @Value("${teleport.jwks-uri}") String teleportJwksUri,
            @Value("${teleport.validation.enabled:true}") boolean validationEnabled) {
        this.tokenMinter = tokenMinter;
        this.validationEnabled = validationEnabled;

        log.info("TeleportToAgentCoreTokenFilter initializing");
        log.info("Validation enabled: {}", validationEnabled);
        log.info("JWKS URI: {}", teleportJwksUri);

        if (validationEnabled) {
            // Validate signature and expiration
            log.info("Creating validating JWT decoder");
            this.jwtDecoder = NimbusJwtDecoder.withJwkSetUri(teleportJwksUri).build();
        } else {
            // Decode without validation - use custom decoder
            log.info("Creating non-validating JWT decoder");
            this.jwtDecoder = token -> {
                try {
                    JWT jwt = JWTParser.parse(token);
                    Map<String, Object> headers = jwt.getHeader().toJSONObject();
                    Map<String, Object> claims = jwt.getJWTClaimsSet().getClaims();
                    Instant issuedAt = jwt.getJWTClaimsSet().getIssueTime() != null
                            ? jwt.getJWTClaimsSet().getIssueTime().toInstant()
                            : Instant.now();
                    Instant expiresAt = jwt.getJWTClaimsSet().getExpirationTime() != null
                            ? jwt.getJWTClaimsSet().getExpirationTime().toInstant()
                            : null;
                    return new Jwt(token, issuedAt, expiresAt, headers, claims);
                } catch (Exception e) {
                    throw new RuntimeException("Failed to parse JWT", e);
                }
            };
        }
        log.info("TeleportToAgentCoreTokenFilter initialized successfully");
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        log.debug("TeleportToAgentCoreTokenFilter.filter() called");
        log.debug("Request path: {}", exchange.getRequest().getPath());

        // Try Teleport-specific header first (used with mTLS)
        // Note: Ingress controllers may lowercase headers, so check both variants
        String token = exchange.getRequest()
                .getHeaders()
                .getFirst("X-Teleport-Jwt-Assertion");

        if (token == null) {
            token = exchange.getRequest()
                    .getHeaders()
                    .getFirst("teleport-jwt-assertion");
        }

        if (token != null) {
            log.debug("Found JWT in Teleport-Jwt-Assertion header");
        } else {
            // Fall back to standard Authorization header
            String authHeader = exchange.getRequest()
                    .getHeaders()
                    .getFirst(HttpHeaders.AUTHORIZATION);

            log.debug("Authorization header: {}", authHeader != null ? "present" : "missing");

            if (authHeader != null && authHeader.startsWith("Bearer ")) {
                token = authHeader.substring(7);
                log.debug("Found JWT in Authorization: Bearer header");
            }
        }

        if (token == null) {
            log.debug("No JWT found in X-Teleport-Jwt-Assertion or Authorization headers, passing through without modification");
            return chain.filter(exchange);
        }

        final String teleportToken = token;
        log.debug("Processing JWT token...");

        return Mono.fromCallable(() -> {
                    // Decode Teleport JWT (validates only if validation enabled)
                    log.debug("Decoding Teleport JWT...");
                    Jwt teleportJwt = jwtDecoder.decode(teleportToken);
                    log.debug("JWT decoded successfully. Claims: {}", teleportJwt.getClaims().keySet());

                    // Extract username claim (Teleport uses 'username', not 'user_name')
                    String username = teleportJwt.getClaimAsString("username");
                    log.debug("Extracted username: {}", username);
                    if (username == null) {
                        log.error("Missing username claim in JWT. Available claims: {}", teleportJwt.getClaims().keySet());
                        throw new IllegalArgumentException("Missing username claim");
                    }

                    // Carry forward additional claims
                    Map<String, Object> additionalClaims = new HashMap<>();
                    if (teleportJwt.getClaimAsStringList("roles") != null) {
                        additionalClaims.put("teleport_roles",
                                teleportJwt.getClaimAsStringList("roles"));
                    }

                    // Mint new token
                    log.debug("Minting new AgentCore token for user: {}", username);
                    String newToken = tokenMinter.mintToken(username, additionalClaims);
                    log.debug("Successfully minted new token");
                    return newToken;
                })
                .subscribeOn(Schedulers.boundedElastic())
                .flatMap(agentCoreToken -> {
                    log.debug("Setting Authorization header with new AgentCore token");
                    log.debug("New AgentCore token: {}", agentCoreToken);

                    ServerHttpRequest mutatedRequest = exchange.getRequest()
                            .mutate()
                            .headers(h -> {
                                // Remove Teleport JWT headers (not needed by AgentCore)
                                h.remove("X-Teleport-Jwt-Assertion");
                                h.remove("teleport-jwt-assertion");
                                // Remove Authorization header if it exists
                                h.remove("Authorization");
                                // Set the new AgentCore JWT
                                h.set("Authorization", "Bearer " + agentCoreToken);
                                log.debug("Authorization header set successfully");
                            })
                            .build();

                    return chain.filter(exchange.mutate().request(mutatedRequest).build());
                })
                .onErrorResume(e -> {
                    log.error("Error in TeleportToAgentCoreTokenFilter: {}", e.getClass().getName());
                    log.error("Error message: {}", e.getMessage(), e);
                    exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
                    return exchange.getResponse().setComplete();
                });
    }

    @Override
    public int getOrder() {
        return -10;
    }
}
