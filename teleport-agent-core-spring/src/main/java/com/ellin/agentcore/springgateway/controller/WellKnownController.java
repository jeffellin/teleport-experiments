package com.ellin.agentcore.springgateway.controller;

import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKMatcher;
import com.nimbusds.jose.jwk.JWKSelector;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/.well-known")
public class WellKnownController {

    private final JWKSource<SecurityContext> jwkSource;
    private final String issuer;

    public WellKnownController(
            JWKSource<SecurityContext> jwkSource,
            @Value("${agentcore.issuer}") String issuer) {
        this.jwkSource = jwkSource;
        this.issuer = issuer;
    }

    /**
     * JWKS endpoint - exposes public keys for JWT verification
     * AgentCore will use this to verify JWTs minted by this gateway
     */
    @GetMapping(value = "/jwks.json", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> jwks() {
        try {
            // Create a selector that matches all keys
            JWKSelector selector = new JWKSelector(new JWKMatcher.Builder().build());

            // Get all keys from the source
            List<JWK> keys = jwkSource.get(selector, null);

            // Create JWKSet and return as JSON
            JWKSet jwkSet = new JWKSet(keys);
            return Mono.just(jwkSet.toJSONObject());
        } catch (Exception e) {
            Map<String, Object> error = new HashMap<>();
            error.put("error", "Failed to retrieve JWKS");
            error.put("message", e.getMessage());
            return Mono.just(error);
        }
    }

    /**
     * OpenID Connect Discovery endpoint
     * Provides metadata about this authorization server
     */
    @GetMapping(value = "/openid-configuration", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> openidConfiguration() {
        Map<String, Object> config = new HashMap<>();

        config.put("issuer", issuer);
        config.put("jwks_uri", issuer + "/.well-known/jwks.json");

        // Supported signing algorithms
        config.put("id_token_signing_alg_values_supported", List.of("RS256"));

        // Token endpoint (not implemented but included for completeness)
        config.put("token_endpoint", issuer + "/token");

        // Supported grant types
        config.put("grant_types_supported", List.of("client_credentials"));

        // Supported response types
        config.put("response_types_supported", List.of("token"));

        // Supported scopes
        config.put("scopes_supported", List.of("mcp:invoke", "mcp:tools"));

        return Mono.just(config);
    }
}