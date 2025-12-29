package com.ellin.agentcore.springgateway.service;

import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;
import org.springframework.stereotype.Service;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Map;

@Service
public class AgentCoreTokenMinter {

    private final JwtEncoder jwtEncoder;
    private final String issuer;
    private final String audience;

    public AgentCoreTokenMinter(
            JWKSource<SecurityContext> jwkSource,
            @Value("${agentcore.issuer}") String issuer,
            @Value("${agentcore.audience}") String audience) {
        this.jwtEncoder = new NimbusJwtEncoder(jwkSource);
        this.issuer = issuer;
        this.audience = audience;
    }

    public String mintToken(String teleportUsername, Map<String, Object> additionalClaims) {
        Instant now = Instant.now();

        JwtClaimsSet claims = JwtClaimsSet.builder()
                .issuer(issuer)
                .issuedAt(now)
                .expiresAt(now.plus(1, ChronoUnit.HOURS))
                .subject(teleportUsername)                          // Identity preserved
                .audience(List.of(audience))
                .claim("scope", "mcp:invoke mcp:tools")
                .claim("username", teleportUsername)                // Explicit claim
                .claim("user_name", teleportUsername)               // Alternative claim format for compatibility
                .claim("auth_source", "teleport")                   // Provenance
                .claims(c -> c.putAll(additionalClaims))
                .build();

        JwsHeader header = JwsHeader.with(SignatureAlgorithm.RS256).build();

        return jwtEncoder.encode(JwtEncoderParameters.from(header, claims))
                .getTokenValue();
    }
}
