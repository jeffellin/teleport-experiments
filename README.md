# Teleport Experiments

This repo contains projects for working with AWS Bedrock AgentCore and Teleport.

## Projects

- `outbound_auth_3lo/`
  - Notebook-driven sample that demonstrates AgentCore Runtime with outbound OAuth 3LO to Google (Calendar).
  - Includes a local OAuth2 callback server used for session binding during the consent flow.
  - See [outbound_auth_3lo/runtime_with_strands_and_egress_3lo.ipynb](outbound_auth_3lo/runtime_with_strands_and_egress_3lo.ipynb) for the step-by-step notebook.

- `teleport-agent-core-spring/`
  - Spring Cloud Gateway that transforms Teleport JWTs into AgentCore-trusted JWTs.
  - Acts as a production-ready identity-preserving proxy in front of AgentCore Gateway.
  - See [teleport-agent-core-spring/README.md](teleport-agent-core-spring/README.md) for details.

- `teleport-mcp-agent-core/`
  - Three-notebook series showing how to MCP-ify AWS Lambda functions behind AgentCore Gateway, protected by Teleport as the OIDC identity provider.
  - Demonstrates zero-trust identity propagation, REQUEST interceptor identity injection, and Cedar/AVP policy enforcement — all without modifying the tool Lambda.
  - See [teleport-mcp-agent-core/README.md](teleport-mcp-agent-core/README.md) for details.

- `tbot-lambda-svid-demo/`
  - A Go Lambda runs `tbot` as an external extension, obtains a SPIFFE X509-SVID from Teleport Workload Identity, and uses it as its TLS client certificate to log in to PostgreSQL.
  - The function stores no secrets: no database password, no join token secret, no long-lived certificates. Identity comes from the Lambda's execution role via the IAM join method.
  - Includes Terraform for both the demo and an EC2 Postgres host, plus a notebook that drives the whole thing in ordered, idempotent cells.
  - See [tbot-lambda-svid-demo/README.md](tbot-lambda-svid-demo/README.md) and [tbot-lambda-svid-demo/demo-walkthrough.ipynb](tbot-lambda-svid-demo/demo-walkthrough.ipynb).
