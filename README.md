# Teleport Experiments

This repo contains two related projects for working with AWS Bedrock AgentCore and Teleport.

## Projects

- `outbound_auth_3lo/`
  - Notebook-driven sample that demonstrates AgentCore Runtime with outbound OAuth 3LO to Google (Calendar).
  - Includes a local OAuth2 callback server used for session binding during the consent flow.
  - See [outbound_auth_3lo/runtime_with_strands_and_egress_3lo.ipynb](outbound_auth_3lo/runtime_with_strands_and_egress_3lo.ipynb) for the step-by-step notebook.

- `teleport-agent-core-spring/`
  - Spring Cloud Gateway that transforms Teleport JWTs into AgentCore-trusted JWTs.
  - Acts as a production-ready identity-preserving proxy in front of AgentCore Gateway.
  - See [teleport-agent-core-spring/README.md](teleport-agent-core-spring/README.md) for details.
