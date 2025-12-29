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

        log.info("=== Incoming Request ===");
        log.info("Method: {}", request.getMethod());
        log.info("URI: {}", request.getURI());
        log.info("Path: {}", request.getPath());
        log.info("Headers:");
        request.getHeaders().forEach((name, values) -> {
            values.forEach(value -> {
                // Log all headers including full JWT tokens for verification
                log.info("  {}: {}", name, value);
            });
        });

        return chain.filter(exchange).then(Mono.fromRunnable(() -> {
            ServerHttpResponse response = exchange.getResponse();

            log.info("=== Outgoing Response ===");
            log.info("Status Code: {}", response.getStatusCode());
            log.info("Response Headers:");
            response.getHeaders().forEach((name, values) -> {
                values.forEach(value -> log.info("  {}: {}", name, value));
            });
            log.info("========================");
        }));
    }

    @Override
    public int getOrder() {
        // Run after TeleportToAgentCoreTokenFilter (which has order -10)
        return -5;
    }
}
