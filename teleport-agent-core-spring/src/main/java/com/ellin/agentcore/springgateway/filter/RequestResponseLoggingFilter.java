package com.ellin.agentcore.springgateway.filter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

@Component
public class RequestResponseLoggingFilter implements GlobalFilter, Ordered {

    private static final Logger log = LoggerFactory.getLogger(RequestResponseLoggingFilter.class);

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();

        log.debug("=== Incoming Request ===");
        log.debug("Method: {}", request.getMethod());
        log.debug("URI: {}", request.getURI());
        log.debug("Path: {}", request.getPath());
        log.debug("Headers:");
        request.getHeaders().forEach((name, values) -> {
            values.forEach(value -> {
                // Log all headers including full JWT tokens for verification
                log.debug("  {}: {}", name, value);
            });
        });

        return chain.filter(exchange).then(Mono.fromRunnable(() -> {
            ServerHttpResponse response = exchange.getResponse();

            log.debug("=== Outgoing Response ===");
            log.debug("Status Code: {}", response.getStatusCode());
            log.debug("Response Headers:");
            response.getHeaders().forEach((name, values) -> {
                values.forEach(value -> log.debug("  {}: {}", name, value));
            });
            log.debug("========================");
        }));
    }

    @Override
    public int getOrder() {
        // Run after TeleportToAgentCoreTokenFilter (which has order -10)
        return -5;
    }
}
