package com.ellin.agentcore.springgateway.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;

@Configuration
@EnableWebFluxSecurity
public class SecurityConfig {

    @Bean
    public SecurityWebFilterChain securityFilterChain(ServerHttpSecurity http) {
        http
                .authorizeExchange(authorize ->
                        authorize
                                // Allow all requests - JWT validation is handled by TeleportToAgentCoreTokenFilter
                                .anyExchange().permitAll()
                )
                .csrf(ServerHttpSecurity.CsrfSpec::disable);

        return http.build();
    }
}
