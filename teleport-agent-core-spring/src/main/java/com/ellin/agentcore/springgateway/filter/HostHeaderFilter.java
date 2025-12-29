package com.ellin.agentcore.springgateway.filter;

import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.URI;

/**
 * Updates the Host header to match the target backend URI.
 * This ensures the backend receives the correct Host header instead of the gateway's hostname.
 */
@Component
public class HostHeaderFilter implements GlobalFilter, Ordered {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        URI targetUri = exchange.getAttribute("org.springframework.cloud.gateway.support.ServerWebExchangeUtils.gatewayRequestUrl");

        if (targetUri != null) {
            ServerHttpRequest mutatedRequest = exchange.getRequest()
                    .mutate()
                    .header("Host", targetUri.getHost() + (targetUri.getPort() != -1 && targetUri.getPort() != 80 && targetUri.getPort() != 443 ? ":" + targetUri.getPort() : ""))
                    .build();

            return chain.filter(exchange.mutate().request(mutatedRequest).build());
        }

        return chain.filter(exchange);
    }

    @Override
    public int getOrder() {
        // Run after RouteToRequestUrlFilter (10000) which sets the gatewayRequestUrl
        // Run before AgentCoreLoggingFilter (10002) so logs show the updated Host header
        return 10001;
    }
}
