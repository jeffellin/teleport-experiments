package com.ellin.agentcore.springgateway.filter;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.URI;

/**
 * Logs outbound requests to AgentCore backend and responses received from AgentCore.
 * Runs late in the filter chain (order 9999) to capture the final request state.
 */
@Component
public class AgentCoreLoggingFilter implements GlobalFilter, Ordered {

    private static final Logger log = LoggerFactory.getLogger(AgentCoreLoggingFilter.class);

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        long startTime = System.currentTimeMillis();

        // Log outbound request to AgentCore
        ServerHttpRequest request = exchange.getRequest();
        URI targetUri = exchange.getAttribute("org.springframework.cloud.gateway.support.ServerWebExchangeUtils.gatewayRequestUrl");

        if (targetUri != null) {
            log.info("=== Outbound Request to AgentCore ===");
            log.info("Method: {}", request.getMethod());
            log.info("Target URI: {}", targetUri);
            log.info("Path: {}", request.getPath());
            log.info("Headers:");
            request.getHeaders().forEach((name, values) -> {
                values.forEach(value -> {
                    // Log all headers including full JWT tokens for verification
                    log.info("  {}: {}", name, value);
                });
            });
            log.info("=====================================");
        }

        return chain.filter(exchange).then(Mono.fromRunnable(() -> {
            long duration = System.currentTimeMillis() - startTime;

            log.info("=== Response from AgentCore ===");
            log.info("Status Code: {}", exchange.getResponse().getStatusCode());
            log.info("Duration: {}ms", duration);
            log.info("Response Headers:");
            exchange.getResponse().getHeaders().forEach((name, values) -> {
                values.forEach(value -> log.info("  {}: {}", name, value));
            });
            log.info("================================");
        }));
    }

    @Override
    public int getOrder() {
        // Run after HostHeaderFilter (10001) which updates the Host header
        // and before routing filters (NettyRoutingFilter at 2147483647)
        return 10002;
    }
}
