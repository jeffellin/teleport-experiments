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
     * Provides minimal metadata for JWT validation only
     * AgentCore will use this to discover the JWKS endpoint and validate JWTs
     *
     * Note: This is NOT an OAuth2 authorization server - we don't issue tokens via OAuth2 flows.
     * JWTs are minted internally by the gateway and sent directly to AgentCore.
     * AgentCore only needs to validate the JWT signature and claims.
     */
    @GetMapping(value = "/openid-configuration", produces = MediaType.APPLICATION_JSON_VALUE)
    public Mono<Map<String, Object>> openidConfiguration() {
        Map<String, Object> config = new HashMap<>();

        // Essential fields for JWT validation
        config.put("issuer", issuer);  // Matches the 'iss' claim in minted JWTs
        config.put("jwks_uri", issuer + "/.well-known/jwks.json");  // Where to get public keys
        config.put("id_token_signing_alg_values_supported", List.of("RS256"));  // Signature algorithm
        config.put("subject_types_supported", List.of("public"));  // OIDC standard field

        // No token_endpoint - we don't implement OAuth2 token issuance
        // No grant_types_supported - we don't support OAuth2 flows
        // JWTs are provided directly in Authorization header

        return Mono.just(config);
    }
}