# AgentCore Identity Propagation: Keycloak to Multi-Agent Architecture

## Overview

This guide covers implementing identity propagation between agents in AWS Bedrock AgentCore when using Keycloak as your OAuth/OIDC provider. The goal is to have Agent A (protected by Keycloak JWT auth) call Agent B while preserving the original user's identity.

## Architecture

```
                              Keycloak
                     ┌─────────────────────┐
                     │  Realm: your-realm  │
                     │  Users: alice, bob  │
                     └─────────────────────┘
                               │
                               │ JWT Token (sub: alice)
                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Agent A (JWT Inbound Auth via Keycloak)                                    │
│                                                                              │
│  1. Receives Keycloak JWT with user identity (sub: alice)                   │
│  2. Extracts user_id from JWT claims                                        │
│  3. Calls Agent B via SigV4 + X-Amzn-Bedrock-AgentCore-Runtime-User-Id      │
└─────────────────────────────────────────────────────────────────────────────┘
                               │
                               │ SigV4 + Header: X-Amzn-...-User-Id: alice
                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Agent B (IAM SigV4 Inbound Auth)                                           │
│                                                                              │
│  1. Receives request authenticated via IAM (Agent A's execution role)       │
│  2. User identity "alice" available via context                             │
│  3. Can use @requires_access_token to get OAuth tokens for "alice"          │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Approach: SigV4 + X-Amzn-Bedrock-AgentCore-Runtime-User-Id Header

This approach uses IAM authentication (SigV4) for agent-to-agent calls while propagating the original user's identity via a special header.

### Key Components

| Component | Configuration |
|-----------|---------------|
| Agent A Inbound Auth | Custom JWT Authorizer → Keycloak discovery URL |
| Agent A → Agent B | IAM SigV4 + User-Id header |
| Agent B Inbound Auth | IAM SigV4 (default, no authorizer config) |

---

## Implementation

### Step 1: Deploy Agent A (JWT Inbound Auth with Keycloak)

```bash
agentcore configure --entrypoint agent_a.py \
  --name agent-a \
  --execution-role arn:aws:iam::111122223333:role/AgentAExecutionRole \
  --requirements-file requirements.txt \
  --authorizer-config '{
    "customJWTAuthorizer": {
      "discoveryUrl": "https://your-keycloak.com/realms/your-realm/.well-known/openid-configuration",
      "allowedClients": ["your-client-id"]
    }
  }' \
  --request-header-allowlist "Authorization"

agentcore launch
```

### Step 2: Deploy Agent B (IAM SigV4 Auth)

```bash
agentcore configure --entrypoint agent_b.py \
  --name agent-b \
  --execution-role arn:aws:iam::111122223333:role/AgentBExecutionRole \
  --requirements-file requirements.txt
  # No --authorizer-config means IAM SigV4 auth (default)

agentcore launch
```

### Step 3: Agent A Code

```python
import json
import jwt
import boto3
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from strands import Agent

app = BedrockAgentCoreApp()
agent = Agent()

AGENT_B_ARN = "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/agent-b-id"


def extract_user_id_from_jwt(auth_header: str) -> str:
    """Extract user identity from Keycloak JWT."""
    if not auth_header:
        return None
    
    token = auth_header.replace('Bearer ', '') if auth_header.startswith('Bearer ') else auth_header
    
    try:
        # Decode without verification - Runtime already validated the token
        claims = jwt.decode(token, options={"verify_signature": False})
        user_id = claims.get('sub')
        
        # If using multiple IdPs, prefix to avoid collisions:
        # user_id = f"keycloak+{claims.get('sub')}"
        
        return user_id
        
    except jwt.InvalidTokenError as e:
        app.logger.exception(f"Failed to decode JWT: {e}")
        return None


def call_agent_b(user_id: str, prompt: str, original_jwt: str = None) -> dict:
    """Call Agent B with user identity propagation."""
    
    client = boto3.client('bedrock-agentcore', region_name='us-east-1')
    event_system = client.meta.events
    
    USER_ID_HEADER = 'X-Amzn-Bedrock-AgentCore-Runtime-User-Id'
    
    def add_user_id_header(request, **kwargs):
        request.headers.add_header(USER_ID_HEADER, user_id)
    
    handler = event_system.register_first(
        'before-sign.bedrock-agentcore.InvokeAgentRuntime',
        add_user_id_header
    )
    
    try:
        # Include original JWT in payload for Agent B to verify
        payload_data = {
            "prompt": prompt,
            "jwt": original_jwt,
            "user_id": user_id
        }
        payload = json.dumps(payload_data).encode()
        
        response = client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_B_ARN,
            runtimeSessionId=f"session-{user_id}",
            payload=payload,
            qualifier="DEFAULT"
        )
        
        content = []
        for chunk in response.get("response", []):
            content.append(chunk.decode('utf-8'))
        
        return json.loads(''.join(content))
        
    finally:
        event_system.unregister(
            'before-sign.bedrock-agentcore.InvokeAgentRuntime',
            handler
        )


@app.entrypoint
def invoke(payload, context: RequestContext):
    """Main entry point for Agent A."""
    
    user_message = payload.get("prompt", "Hello")
    auth_header = context.request_headers.get('Authorization')
    user_id = extract_user_id_from_jwt(auth_header)
    
    if not user_id:
        return {"error": "Could not extract user identity from token"}
    
    # Delegate to Agent B when needed
    if "delegate" in user_message.lower() or "agent b" in user_message.lower():
        result = call_agent_b(user_id, user_message, auth_header)
        return {
            "source": "agent-a",
            "delegated_to": "agent-b", 
            "user_id": user_id,
            "result": result
        }
    
    # Handle locally
    response = agent(user_message)
    return {"source": "agent-a", "user_id": user_id, "result": str(response)}


if __name__ == "__main__":
    app.run()
```

### Step 4: Agent B Code

```python
import json
import jwt
from bedrock_agentcore import BedrockAgentCoreApp, RequestContext
from strands import Agent

app = BedrockAgentCoreApp()
agent = Agent()

# Keycloak public keys URL for JWT verification
KEYCLOAK_JWKS_URL = "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/certs"


def validate_jwt_with_keycloak(token: str) -> dict:
    """Validate JWT signature against Keycloak."""
    import requests
    from jwt import PyJWKClient
    
    if token.startswith('Bearer '):
        token = token[7:]
    
    jwks_client = PyJWKClient(KEYCLOAK_JWKS_URL)
    signing_key = jwks_client.get_signing_key_from_jwt(token)
    
    claims = jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience="your-client-id",
        issuer="https://your-keycloak.com/realms/your-realm"
    )
    
    return claims


@app.entrypoint  
def invoke(payload, context: RequestContext):
    """Main entry point for Agent B."""
    
    user_message = payload.get("prompt", "Hello from Agent B")
    user_id_from_header = payload.get("user_id")
    jwt_token = payload.get("jwt")
    
    # Verify JWT if provided (defense in depth)
    if jwt_token:
        try:
            claims = validate_jwt_with_keycloak(jwt_token)
            
            # Verify user-id matches JWT subject
            if claims.get('sub') != user_id_from_header:
                app.logger.error(f"User-id mismatch: header={user_id_from_header}, jwt.sub={claims.get('sub')}")
                return {"error": "unauthorized", "message": "Identity mismatch"}
            
            app.logger.info(f"User {user_id_from_header} verified via JWT")
            
        except jwt.InvalidTokenError as e:
            app.logger.error(f"JWT validation failed: {e}")
            return {"error": "unauthorized", "message": "Invalid token"}
    
    # Process request
    response = agent(user_message)
    return {"source": "agent-b", "user_id": user_id_from_header, "result": str(response)}


if __name__ == "__main__":
    app.run()
```

### Step 5: IAM Permissions

Agent A's execution role needs permission to invoke Agent B with the user ID header:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "InvokeAgentB",
            "Effect": "Allow",
            "Action": [
                "bedrock-agentcore:InvokeAgentRuntime",
                "bedrock-agentcore:InvokeAgentRuntimeForUser"
            ],
            "Resource": [
                "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/agent-b-id"
            ]
        }
    ]
}
```

**Important:** The `InvokeAgentRuntimeForUser` action is required when passing the `X-Amzn-Bedrock-AgentCore-Runtime-User-Id` header.

---

## Security Considerations

### What Prevents User-Id Header Spoofing?

The security is enforced by **IAM permissions**:

| Caller | Has InvokeAgentRuntime | Has InvokeAgentRuntimeForUser | Can Set User-Id? |
|--------|------------------------|-------------------------------|------------------|
| Random attacker | ❌ No | ❌ No | ❌ No |
| User via JWT auth | N/A | N/A | ❌ No (from JWT) |
| Service with basic IAM | ✅ Yes | ❌ No | ❌ No (ignored) |
| Agent A's execution role | ✅ Yes | ✅ Yes | ✅ Yes (trusted) |

**Key points:**
- Only principals with `InvokeAgentRuntimeForUser` permission can set the header
- AgentCore treats the user-id as an opaque identifier and trusts the caller
- Your responsibility: Only grant `InvokeAgentRuntimeForUser` to trusted service roles

### Is the Original JWT Passed to Agent B?

**No, not automatically.** The SigV4 + User-Id approach only passes:
- IAM identity (Agent A's role)
- User-Id header value
- Payload

To pass the JWT:
1. Include it in the payload (recommended)
2. Use a custom header (`X-Amzn-Bedrock-AgentCore-Runtime-Custom-*`)

### User-Level Authorization (Who Can Use Agent B via Agent A?)

**AgentCore does NOT automatically restrict which users can reach Agent B through Agent A.** You must implement this yourself.

#### Option 1: Authorization in Agent A (Recommended)

```python
AGENT_B_ALLOWED_ROLES = ['premium-user', 'admin']

@app.entrypoint
def invoke(payload, context):
    auth_header = context.request_headers.get('Authorization')
    claims = jwt.decode(auth_header.replace('Bearer ', ''), options={"verify_signature": False})
    user_id = claims.get('sub')
    user_roles = claims.get('realm_access', {}).get('roles', [])
    
    if needs_agent_b(payload):
        # Check authorization
        if not any(role in AGENT_B_ALLOWED_ROLES for role in user_roles):
            return {"error": "forbidden", "message": "Not authorized for Agent B"}
        
        return call_agent_b(user_id, payload, auth_header)
```

#### Option 2: IAM Condition on User-Id

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["bedrock-agentcore:InvokeAgentRuntime", "bedrock-agentcore:InvokeAgentRuntimeForUser"],
            "Resource": "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/agent-b-*",
            "Condition": {
                "StringEquals": {
                    "bedrock-agentcore:userid": ["alice", "bob", "admin"]
                }
            }
        }
    ]
}
```

#### Option 3: Independent Verification in Agent B (Defense in Depth)

```python
@app.entrypoint
def invoke(payload, context):
    user_id_from_header = payload.get("user_id")
    jwt_token = payload.get("jwt")
    
    if jwt_token:
        claims = validate_jwt_with_keycloak(jwt_token)
        
        # Verify identity match
        if claims.get('sub') != user_id_from_header:
            return {"error": "forbidden", "message": "Identity mismatch"}
        
        # Additional authorization
        if not check_authorization(claims, required_roles=['premium-user']):
            return {"error": "forbidden", "message": "Not authorized"}
```

---

## Token Vault

The AgentCore Token Vault is relevant when agents need to call external OAuth-protected services on behalf of users.

### When Token Vault is Used

| Scenario | Token Vault Used? |
|----------|-------------------|
| Agent calls Google/Slack/GitHub on behalf of user | ✅ Yes |
| Agent uses service account (M2M) | ✅ Yes |
| Agent A calls Agent B (this guide) | ⚠️ Not required |
| Agent B calls Keycloak-protected downstream service | Depends on approach |

### Key Limitation

Tokens are scoped to **(workload_identity + user_id)**. Agent B cannot access tokens stored by Agent A, even for the same user.

### For Agent-to-Agent with Same Keycloak

If Agent B needs to call Keycloak-protected resources:

1. **Token Passthrough**: Pass original JWT from Agent A → Agent B → downstream service
2. **Token Exchange**: Configure Keycloak token exchange (RFC 8693) for Agent B to get its own token

---

## Multi-Layer Security Architecture

```
User (alice) ──► Agent A ──► Agent B ──► Downstream Services

Layer 1: Keycloak JWT Validation (Agent A inbound)
  ✓ Valid signature
  ✓ Not expired  
  ✓ Correct audience/client_id

Layer 2: Application Authorization (Agent A code)
  ✓ User has required role/scope for Agent B?
  ✓ User in allowlist?
  → If NO: Return 403

Layer 3: IAM Policy (Agent A → Agent B transport)
  ✓ Agent A's role has InvokeAgentRuntime
  ✓ Agent A's role has InvokeAgentRuntimeForUser
  ✓ (Optional) userid condition

Layer 4: Independent Verification (Agent B code)
  ✓ Validate JWT signature
  ✓ Verify user-id matches JWT subject
  ✓ Additional authorization checks
```

---

## Testing

### Get Keycloak Token

```bash
export TOKEN=$(curl -X POST "https://your-keycloak.com/realms/your-realm/protocol/openid-connect/token" \
  -d "client_id=your-client-id" \
  -d "client_secret=your-client-secret" \
  -d "username=alice" \
  -d "password=alicepassword" \
  -d "grant_type=password" | jq -r '.access_token')
```

### Call Agent A

```bash
curl -X POST "https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/${AGENT_A_ARN}/invocations?qualifier=DEFAULT" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Please delegate this to agent b"}'
```

---

## Requirements

```
# requirements.txt
strands-agents
bedrock-agentcore
PyJWT
requests
```

---

## Summary

| Question | Answer |
|----------|--------|
| How is user identity propagated? | Via `X-Amzn-Bedrock-AgentCore-Runtime-User-Id` header |
| What secures the header from spoofing? | IAM permissions (`InvokeAgentRuntimeForUser` required) |
| Is original JWT passed to Agent B? | Not automatically; include in payload or custom header |
| Who controls which users can use Agent B? | Your code; implement authorization in Agent A and/or B |
| Is Token Vault needed? | Not for agent-to-agent; needed for external OAuth services |

---

## References

- [AgentCore Runtime OAuth Documentation](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-oauth.html)
- [Pass Custom Headers](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-header-allowlist.html)
- [Get Workload Access Token](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/get-workload-access-token.html)
- [Resource-Based Policies](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/resource-based-policies.html)
- [AgentCore Identity Overview](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/identity.html)
