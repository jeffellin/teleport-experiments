package com.ellin.agentcore.springgateway.filter;

import com.ellin.agentcore.springgateway.service.AgentCoreTokenMinter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;
import reactor.core.scheduler.Schedulers;

import java.util.HashMap;
import java.util.Map;

@Component
public class TeleportToAgentCoreTokenFilter implements GlobalFilter, Ordered {

    private final AgentCoreTokenMinter tokenMinter;
    private final NimbusJwtDecoder jwtDecoder;

    public TeleportToAgentCoreTokenFilter(
            AgentCoreTokenMinter tokenMinter,
            @Value("${teleport.jwks-uri}") String teleportJwksUri,
            @Value("${teleport.validation.enabled:true}") boolean validationEnabled) {
        this.tokenMinter = tokenMinter;

        if (validationEnabled) {
            // Validate signature and expiration
            this.jwtDecoder = NimbusJwtDecoder.withJwkSetUri(teleportJwksUri).build();
        } else {
            // Decode without validation
            this.jwtDecoder = NimbusJwtDecoder.withoutValidation().build();
        }
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
                    // Decode Teleport JWT (validates only if validation enabled)
                    Jwt teleportJwt = jwtDecoder.decode(teleportToken);

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
