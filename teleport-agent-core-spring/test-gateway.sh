#!/bin/bash

# Test script for Spring Gateway
# This script tests the gateway with a sample JWT

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

BASE_URL="http://localhost:8080"

echo -e "${YELLOW}=== Spring Gateway Test Script ===${NC}\n"

# Function to create a simple unsigned JWT for testing
# Note: This only works when teleport.validation.enabled=false
create_test_jwt() {
    local header='{"alg":"none","typ":"JWT"}'
    local payload='{
        "user_name": "test-user@example.com",
        "roles": ["developer", "admin"],
        "sub": "test-user@example.com",
        "iat": '$(date +%s)',
        "exp": '$(($(date +%s) + 3600))'
    }'

    # Base64url encode (without padding)
    local header_b64=$(echo -n "$header" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload_b64=$(echo -n "$payload" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    # Unsigned JWT (signature is empty for alg:none)
    echo "${header_b64}.${payload_b64}."
}

# Function to create a signed JWT using HS256 (for testing with validation)
# You'll need to update the secret to match your configuration
create_signed_jwt() {
    local secret="your-secret-key-here"
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload='{
        "user_name": "test-user@example.com",
        "roles": ["developer", "admin"],
        "sub": "test-user@example.com",
        "iat": '$(date +%s)',
        "exp": '$(($(date +%s) + 3600))'
    }'

    # Base64url encode (without padding)
    local header_b64=$(echo -n "$header" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload_b64=$(echo -n "$payload" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    # Create signature
    local signature=$(echo -n "${header_b64}.${payload_b64}" | openssl dgst -sha256 -hmac "$secret" -binary | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    echo "${header_b64}.${payload_b64}.${signature}"
}

echo -e "${GREEN}1. Testing Health Endpoint (No Auth Required)${NC}"
echo "curl $BASE_URL/actuator/health"
echo ""
curl -s "$BASE_URL/actuator/health" | jq . || echo "Failed to reach health endpoint"
echo -e "\n"

echo -e "${GREEN}2. Testing Info Endpoint (No Auth Required)${NC}"
echo "curl $BASE_URL/actuator/info"
echo ""
curl -s "$BASE_URL/actuator/info" | jq . || echo "No info configured"
echo -e "\n"

# Generate test JWT
echo -e "${YELLOW}Note: For testing with JWT validation DISABLED (teleport.validation.enabled=false)${NC}"
JWT=$(create_test_jwt)
echo -e "${GREEN}3. Testing with Unsigned JWT (requires validation.enabled=false)${NC}"
echo "JWT: $JWT"
echo ""
echo "Decoding JWT payload:"
# Add padding and decode (handle both macOS and Linux base64)
PAYLOAD=$(echo "$JWT" | cut -d'.' -f2)
# Add padding if needed
case $((${#PAYLOAD} % 4)) in
    2) PAYLOAD="${PAYLOAD}==" ;;
    3) PAYLOAD="${PAYLOAD}=" ;;
esac
echo "$PAYLOAD" | base64 -d 2>/dev/null | jq . || echo "Could not decode (jq might not be installed)"
echo -e "\n"

echo -e "${GREEN}4. Testing AgentCore /ping endpoint (GET)${NC}"
echo "curl -H \"Authorization: Bearer \$JWT\" $BASE_URL/ping"
echo ""
curl -s -H "Authorization: Bearer $JWT" "$BASE_URL/ping" -w "\nHTTP Status: %{http_code}\n" || echo "Request failed"
echo -e "\n"

echo -e "${GREEN}5. Testing AgentCore /invocations endpoint (POST)${NC}"
echo "curl -X POST -H \"Authorization: Bearer \$JWT\" -H \"Content-Type: application/json\" -d '{\"action\":\"test\"}' $BASE_URL/invocations"
echo ""
curl -s -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{"action":"test"}' "$BASE_URL/invocations" -w "\nHTTP Status: %{http_code}\n" || echo "Request failed"
echo -e "\n"

echo -e "${GREEN}6. Testing AgentCore /mcp endpoint (Model Context Protocol)${NC}"
echo "curl -H \"Authorization: Bearer \$JWT\" $BASE_URL/mcp/tools"
echo ""
curl -s -H "Authorization: Bearer $JWT" "$BASE_URL/mcp/tools" -w "\nHTTP Status: %{http_code}\n" || echo "Request failed"
echo -e "\n"

echo -e "${GREEN}7. Testing httpbin fallback route (GET /get)${NC}"
echo "curl -H \"Authorization: Bearer \$JWT\" $BASE_URL/get"
echo ""
curl -s -H "Authorization: Bearer $JWT" "$BASE_URL/get" -w "\nHTTP Status: %{http_code}\n" || echo "Request failed"
echo -e "\n"

echo -e "${GREEN}8. Testing Without Authorization Header (should pass through without JWT)${NC}"
echo "curl $BASE_URL/get"
echo ""
curl -s "$BASE_URL/get" -w "\nHTTP Status: %{http_code}\n" || echo "Request failed"
echo -e "\n"

echo -e "${YELLOW}=== Test Complete ===${NC}"
echo -e "\n${YELLOW}AgentCore Endpoints Supported:${NC}"
echo "- /ping (GET) - Health check"
echo "- /invocations (POST) - Agent interactions"
echo "- /ws/** (WebSocket) - Real-time bidirectional streaming"
echo "- /mcp/** (Various) - Model Context Protocol server"
echo ""
echo -e "${YELLOW}Tips:${NC}"
echo "- To disable JWT validation for testing, set in application.yml:"
echo "    teleport.validation.enabled: false"
echo ""
echo "- For real Teleport integration, configure:"
echo "    teleport.jwks-uri: https://your-teleport-instance.example.com/webapi/jwks"
echo ""
echo "- To test WebSocket endpoint, install wscat:"
echo "    npm install -g wscat"
echo "    wscat -c \"ws://localhost:8080/ws\" -H \"Authorization: Bearer \$JWT\""
echo ""
echo "- The JWT should contain a 'user_name' claim"
echo "- Optionally include 'roles' claim as an array"
echo ""
echo "See AGENTCORE.md for detailed documentation"