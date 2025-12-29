#!/bin/bash
# Start Spring Gateway with Teleport App Service

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Starting Spring Gateway with Teleport ===${NC}\n"

# Check if token is provided
if [ -z "$1" ]; then
    echo -e "${YELLOW}Usage: $0 <teleport-join-token>${NC}"
    echo ""
    echo "Get a join token from Teleport:"
    echo "  1. Login: tsh login --proxy=ellinj.teleport.sh"
    echo "  2. Create token: tctl tokens add --type=app --ttl=1h"
    echo ""
    echo "Or use an existing token from teleport.yml"
    echo ""
    read -p "Press Enter to start WITHOUT Teleport (local only), or Ctrl+C to exit: "
    TOKEN=""
else
    TOKEN="$1"
fi

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Shutting down...${NC}"
    kill $TELEPORT_PID 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM


# Start Teleport if token provided
if [ -n "$TOKEN" ]; then
    echo -e "${GREEN}2. Starting Teleport App Service${NC}"
    echo "Connecting to: ellinj.teleport.sh"
    echo "App will be available at: https://agentid.ellinj.teleport.sh"
    echo "Proxying to: http://localhost:8082"
    echo ""

    # Create local data directory
    mkdir -p ./teleport-data

    teleport start \
        --config=teleport-app.yml \
        --token="$TOKEN" \
        --app-name=agentid \
        --app-uri=http://localhost:8082 \
        --labels=env=dev,app=spring-gateway \
        --debug &
    TELEPORT_PID=$!

    echo -e "\n${GREEN}✓ Teleport App Service is running${NC}\n"
    echo -e "${YELLOW}Users can now access:${NC}"
    echo "  tsh app login agentid"
    echo "  curl https://agentcoregateway.ellinj.teleport.sh/actuator/health"
else
    echo -e "${YELLOW}Running without Teleport (local only)${NC}\n"
    echo "To add Teleport later, restart with:"
    echo "  $0 <your-join-token>"
fi

echo ""
echo -e "${GREEN}=== Services Running ===${NC}"
if [ -n "$TOKEN" ]; then
    echo "Teleport App: https://agentid.ellinj.teleport.sh → http://localhost:8082"
    echo "Local Gateway: http://localhost:8082"
fi
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# Wait for processes
wait
