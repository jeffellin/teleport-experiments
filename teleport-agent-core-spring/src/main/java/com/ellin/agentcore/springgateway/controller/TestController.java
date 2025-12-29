package com.ellin.agentcore.springgateway.controller;

import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

@RestController
@RequestMapping("/test")
public class TestController {

    /**
     * Echo endpoint - returns the JWT and decoded payload
     * Use this to verify your gateway is transforming JWTs correctly
     */
    @GetMapping("/echo")
    public Mono<ResponseEntity<Map<String, Object>>> echo(ServerWebExchange exchange) {
        Map<String, Object> response = new HashMap<>();

        // Check for Teleport JWT header (mTLS)
        // Note: Ingress controllers may lowercase headers, so check both variants
        String teleportJwt = exchange.getRequest().getHeaders().getFirst("X-Teleport-Jwt-Assertion");
        if (teleportJwt == null) {
            teleportJwt = exchange.getRequest().getHeaders().getFirst("teleport-jwt-assertion");
        }
        String authHeader = exchange.getRequest().getHeaders().getFirst(HttpHeaders.AUTHORIZATION);

        String jwt = null;
        String source = null;

        if (teleportJwt != null) {
            jwt = teleportJwt;
            source = "Teleport-Jwt-Assertion";
        } else if (authHeader != null && authHeader.startsWith("Bearer ")) {
            jwt = authHeader.substring(7);
            source = "Authorization: Bearer";
        }

        if (jwt != null) {
            response.put("jwt_source", source);
            response.put("jwt_token", jwt);

            // Decode JWT payload
            try {
                String[] parts = jwt.split("\\.");
                if (parts.length >= 2) {
                    String payload = parts[1];
                    // Add padding if needed
                    int padding = (4 - payload.length() % 4) % 4;
                    payload += "====".substring(0, padding);

                    byte[] decodedBytes = Base64.getUrlDecoder().decode(payload);
                    String decodedPayload = new String(decodedBytes);
                    response.put("jwt_payload_decoded", decodedPayload);
                }
            } catch (Exception e) {
                response.put("jwt_decode_error", e.getMessage());
            }
        } else {
            response.put("error", "No JWT found in X-Teleport-Jwt-Assertion or Authorization headers");
        }

        response.put("path", exchange.getRequest().getPath().toString());
        response.put("method", exchange.getRequest().getMethod().toString());

        return Mono.just(ResponseEntity.ok(response));
    }

    /**
     * Ping endpoint for testing
     */
    @GetMapping("/ping")
    public Mono<ResponseEntity<Map<String, Object>>> ping() {
        Map<String, Object> response = new HashMap<>();
        response.put("status", "ok");
        response.put("message", "Gateway is running");
        return Mono.just(ResponseEntity.ok(response));
    }
}