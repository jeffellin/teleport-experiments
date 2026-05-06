#!/usr/bin/env bash
set -euo pipefail

APP="${1:-agentcore-gateway}"
ORDER_ID="${2:-test-order-123}"

run_mcp() {
  printf '%s\n' "$@" | tsh mcp connect "$APP" 2>/dev/null
}

echo "=== initialize + tools/list ==="
run_mcp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

echo ""
echo "=== get_order (orderId=$ORDER_ID) ==="
run_mcp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"LambdaUsingSDK___get_order_tool\",\"arguments\":{\"orderId\":\"$ORDER_ID\"}}}"