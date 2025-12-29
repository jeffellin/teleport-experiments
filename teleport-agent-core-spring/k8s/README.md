# Kubernetes Deployment

This directory contains Kubernetes manifests for deploying the Spring Cloud Gateway with Contour ingress, TLS certificates, and AgentCore integration.

**Status**: ✅ **Working and Deployed**

## Overview

The deployment includes:

- ✅ **ConfigMap** - Application configuration (AgentCore endpoints, Teleport settings)
- ✅ **Deployment** - Spring Gateway pods with health checks
- ✅ **Service** - ClusterIP service exposing port 8080
- ✅ **Ingress** - Contour ingress with TLS (cert-manager managed)
- ✅ **Kustomization** - Kustomize configuration for easy deployment

## Prerequisites

### Required Components

1. **Kubernetes cluster** (1.25+)
   ```bash
   kubectl version --short
   ```

2. **kubectl** configured with cluster access
   ```bash
   kubectl cluster-info
   ```

3. **Contour Ingress Controller** (or compatible ingress like nginx)
   ```bash
   kubectl get svc -n projectcontour envoy
   ```

4. **cert-manager** with `letsencrypt-prod` ClusterIssuer
   ```bash
   kubectl get clusterissuer letsencrypt-prod
   ```

5. **Docker image** pushed to registry
   ```bash
   docker pull ellinj/spring-agent-gateway:latest
   ```

### Installing Prerequisites

If you don't have Contour or cert-manager installed:

#### Install Contour
```bash
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml

# Verify installation
kubectl get pods -n projectcontour
kubectl get svc -n projectcontour envoy
```

#### Install cert-manager
```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Verify installation
kubectl get pods -n cert-manager

# Create Let's Encrypt ClusterIssuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: contour
EOF
```

## Files

| File | Purpose |
|------|---------|
| `configmap.yaml` | Application configuration (AgentCore endpoints, Teleport JWKS) |
| `deployment.yaml` | Deployment with 1 replica, health checks, resource limits |
| `service.yaml` | ClusterIP service exposing port 8080 |
| `ingress.yaml` | Contour ingress with TLS for `agentid.ellin.net` |
| `kustomization.yaml` | Kustomize configuration for easy deployment |

## Configuration

### 1. Update ConfigMap

Edit `configmap.yaml` and configure your endpoints:

```yaml
data:
  application.yml: |
    # Teleport configuration
    teleport:
      jwks-uri: https://ellinj.teleport.sh/.well-known/jwks.json
      validation:
        enabled: false  # Set to true for production

    # AgentCore configuration
    agentcore:
      endpoint: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
      endpoint.ws: wss://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
      endpoint.mcp: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
      issuer: https://agentid.ellin.net  # Must match your domain
      audience: agentcore-gateway
```

### 2. Update Ingress

Edit `ingress.yaml` to configure your domain:

```yaml
spec:
  rules:
  - host: agentid.ellin.net  # Change to your domain
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: spring-gateway
            port:
              number: 8080
  tls:
  - hosts:
    - agentid.ellin.net  # Change to your domain
    secretName: agentid-ellin-net-tls
```

### 3. Update Deployment Image

Edit `deployment.yaml` to use your image:

```yaml
spec:
  template:
    spec:
      containers:
      - name: spring-gateway
        image: ellinj/spring-agent-gateway:latest  # Change to your registry
        imagePullPolicy: Always
```

## Deployment Steps

### 1. Build and Push Docker Image

```bash
# Build for x86/amd64 (most Kubernetes clusters)
make docker-build-x86

# Tag for your registry
docker tag spring-gateway:latest ellinj/spring-agent-gateway:latest

# Push to registry
docker push ellinj/spring-agent-gateway:latest
```

See [BUILD.md](../notes/BUILD.md) for detailed build instructions.

### 2. Configure DNS

Point your domain to the Contour Envoy LoadBalancer:

```bash
# Get LoadBalancer external IP or hostname
kubectl get svc -n projectcontour envoy

# Example output:
# NAME    TYPE           CLUSTER-IP       EXTERNAL-IP                     PORT(S)
# envoy   LoadBalancer   10.100.200.241   a123...us-east-1.elb.amazonaws.com   80:30080/TCP,443:30443/TCP
```

Create DNS record:
- **CNAME**: `agentid.ellin.net` → `<LoadBalancer hostname>`
- **or A record**: `agentid.ellin.net` → `<LoadBalancer IP>`

Verify DNS:
```bash
dig agentid.ellin.net
nslookup agentid.ellin.net
```

### 3. Deploy to Kubernetes

```bash
# Deploy using kustomize (recommended)
kubectl apply -k k8s/

# Or deploy individual files
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

### 4. Verify Deployment

```bash
# Check all resources
kubectl get all -l app=spring-gateway

# Check deployment
kubectl get deployment spring-gateway
kubectl rollout status deployment/spring-gateway

# Check pods
kubectl get pods -l app=spring-gateway
kubectl describe pod -l app=spring-gateway

# Check service
kubectl get svc spring-gateway
kubectl describe svc spring-gateway

# Check ingress
kubectl get ingress spring-gateway
kubectl describe ingress spring-gateway

# Check TLS certificate (created by cert-manager)
kubectl get certificate
kubectl describe certificate agentid-ellin-net-tls

# View logs
kubectl logs -l app=spring-gateway -f --tail=100
```

### 5. Wait for TLS Certificate

cert-manager will automatically provision a Let's Encrypt certificate:

```bash
# Watch certificate creation
kubectl get certificate -w

# Check certificate status
kubectl describe certificate agentid-ellin-net-tls

# When ready, you'll see:
#   Status:
#     Conditions:
#       Type:    Ready
#       Status:  True

# Verify secret was created
kubectl get secret agentid-ellin-net-tls
```

This usually takes 1-2 minutes. If it fails, check cert-manager logs:
```bash
kubectl logs -n cert-manager -l app=cert-manager -f
```

## Testing

### Health Check

```bash
# Via port-forward (bypasses ingress)
kubectl port-forward svc/spring-gateway 8082:8080
curl http://localhost:8082/actuator/health

# Via ingress (requires DNS configured)
curl https://agentid.ellin.net/actuator/health
```

### OIDC Discovery

```bash
# Test OIDC configuration endpoint
curl https://agentid.ellin.net/.well-known/openid-configuration | jq .

# Expected output:
# {
#   "issuer": "https://agentid.ellin.net",
#   "jwks_uri": "https://agentid.ellin.net/.well-known/jwks.json",
#   "id_token_signing_alg_values_supported": ["RS256"],
#   "subject_types_supported": ["public"]
# }
```

### JWKS Endpoint

```bash
# Test JWKS endpoint
curl https://agentid.ellin.net/.well-known/jwks.json | jq .

# Expected output:
# {
#   "keys": [
#     {
#       "kty": "RSA",
#       "e": "AQAB",
#       "use": "sig",
#       "kid": "...",
#       "alg": "RS256",
#       "n": "..."
#     }
#   ]
# }
```

### Test with Teleport

```bash
# Login to Teleport
tsh login --proxy=ellinj.teleport.sh

# Login to the app
tsh app login agentid

# Test echo endpoint (shows JWT transformation)
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo | jq .
```

Expected response showing JWT details:
```json
{
  "jwt_source": "Teleport-Jwt-Assertion",
  "jwt_token": "eyJ...",
  "jwt_payload_decoded": "{\"username\":\"jeffrey.ellin@goteleport.com\",...}",
  "path": "/test/echo",
  "method": "GET"
}
```

## Monitoring and Logs

### View Logs

```bash
# Follow logs from all replicas
kubectl logs -l app=spring-gateway -f --tail=100

# Follow logs from specific pod
kubectl logs <pod-name> -f

# View logs from previous container (after crash)
kubectl logs <pod-name> --previous
```

### Log Output

The gateway logs show comprehensive request/response details:

```
=== Incoming Request ===
Method: POST
URI: https://agentid.ellin.net/invocations
Headers:
  teleport-jwt-assertion: eyJ...
  host: agentid.ellin.net

=== JWT Transformation ===
JWT source: teleport-jwt-assertion
Teleport JWT decoded successfully. Claims: [username, roles, sub, iss, exp, iat]
Extracted username: jeffrey.ellin@goteleport.com
Minted AgentCore JWT with username: jeffrey.ellin@goteleport.com

=== Outbound Request to AgentCore ===
Method: POST
Target URI: https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com/invocations
Headers:
  host: your-gateway.bedrock-agentcore.us-east-2.amazonaws.com
  authorization: Bearer eyJ...

=== Response from AgentCore ===
Status Code: 200 OK
Duration: 245ms
```

### Health Checks

The deployment includes liveness and readiness probes:

```yaml
livenessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
```

## Updates and Rollouts

### Update Configuration

```bash
# Edit ConfigMap
kubectl edit configmap spring-gateway-config

# Or apply updated file
kubectl apply -f k8s/configmap.yaml

# Restart pods to pick up changes
kubectl rollout restart deployment/spring-gateway

# Watch rollout
kubectl rollout status deployment/spring-gateway
```

### Update Image

```bash
# Option 1: Set image directly
kubectl set image deployment/spring-gateway \
  spring-gateway=ellinj/spring-agent-gateway:v1.2.0

# Option 2: Edit deployment
kubectl edit deployment spring-gateway

# Option 3: Apply updated deployment.yaml
kubectl apply -f k8s/deployment.yaml

# Watch rollout
kubectl rollout status deployment/spring-gateway

# View rollout history
kubectl rollout history deployment/spring-gateway

# Rollback if needed
kubectl rollout undo deployment/spring-gateway
```

### Zero-Downtime Deployment

The deployment uses `RollingUpdate` strategy:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```

This ensures:
- New pod starts before old pod terminates
- No service interruption during updates

## Scaling

### Manual Scaling

```bash
# Scale to 3 replicas
kubectl scale deployment spring-gateway --replicas=3

# Verify scaling
kubectl get pods -l app=spring-gateway
```

### Horizontal Pod Autoscaler (HPA)

```bash
# Create HPA based on CPU usage
kubectl autoscale deployment spring-gateway \
  --cpu-percent=70 \
  --min=2 \
  --max=10

# Check HPA status
kubectl get hpa spring-gateway
kubectl describe hpa spring-gateway
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -l app=spring-gateway

# Describe pod
kubectl describe pod <pod-name>

# Common issues:
# - ImagePullBackOff: Check image name and registry credentials
# - CrashLoopBackOff: Check application logs
# - Pending: Check node resources
```

### Image Pull Errors

```bash
# Check events
kubectl describe pod <pod-name> | grep -A10 Events

# If using private registry, create imagePullSecret:
kubectl create secret docker-registry regcred \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  --docker-email=<your-email>

# Add to deployment.yaml:
spec:
  template:
    spec:
      imagePullSecrets:
      - name: regcred
```

### Ingress Not Working

```bash
# Check ingress status
kubectl get ingress spring-gateway
kubectl describe ingress spring-gateway

# Check ingress controller logs
kubectl logs -n projectcontour -l app=contour -f
kubectl logs -n projectcontour -l app=envoy -f

# Verify ingress class
kubectl get ingressclass

# Check Envoy service
kubectl get svc -n projectcontour envoy
```

### TLS Certificate Issues

```bash
# Check certificate status
kubectl get certificate
kubectl describe certificate agentid-ellin-net-tls

# Check certificate request
kubectl get certificaterequest
kubectl describe certificaterequest <name>

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f

# Check challenges (if HTTP01)
kubectl get challenges

# Verify secret was created
kubectl get secret agentid-ellin-net-tls
kubectl describe secret agentid-ellin-net-tls

# Common issues:
# - DNS not propagated: Wait for DNS to update
# - Firewall blocking port 80: HTTP01 challenge needs port 80 open
# - Rate limit: Let's Encrypt has rate limits, use staging first
```

### JWT Validation Errors

```bash
# Check logs for JWT errors
kubectl logs -l app=spring-gateway | grep -i "jwt\|token"

# Common errors:
# - "No JWT found": Teleport not sending header, check Teleport app service
# - "Missing username claim": Wrong claim name, should be 'username' not 'user_name'
# - "teleport-jwt-assertion": Header lowercased by ingress, gateway handles both variants
```

### Teleport Integration Issues

```bash
# Check if Teleport JWT header is present
kubectl logs -l app=spring-gateway | grep -i "teleport-jwt-assertion"

# Should see both variants logged:
# - X-Teleport-Jwt-Assertion (original)
# - teleport-jwt-assertion (lowercased by Contour/Envoy)

# Verify Teleport app service is configured correctly
# - App name: agentid
# - URI: https://agentid.ellin.net
# - Proxy: ellinj.teleport.sh
```

### AgentCore Connection Issues

```bash
# Check outbound requests to AgentCore
kubectl logs -l app=spring-gateway | grep "Outbound Request to AgentCore"

# Verify Host header is updated
kubectl logs -l app=spring-gateway | grep "host:"

# Should see:
# Incoming: host: agentid.ellin.net
# Outbound: host: your-gateway.bedrock-agentcore.us-east-2.amazonaws.com

# Test connectivity to AgentCore
kubectl exec -it <pod-name> -- curl https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com/ping
```

### WebSocket Not Working

```bash
# Verify WebSocket upgrade headers
kubectl logs -l app=spring-gateway | grep -i "upgrade"

# Test WebSocket connection
tsh app login agentid
wscat -c "wss://agentid.ellinj.teleport.sh/ws" \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key

# Contour automatically handles WebSocket upgrade, no special annotation needed
```

### High Memory Usage

```bash
# Check resource usage
kubectl top pod -l app=spring-gateway

# Adjust memory limits in deployment.yaml:
resources:
  limits:
    memory: "1Gi"
  requests:
    memory: "512Mi"

# Apply and restart
kubectl apply -f k8s/deployment.yaml
```

## Cleanup

### Delete All Resources

```bash
# Using kustomize
kubectl delete -k k8s/

# Or delete individually
kubectl delete ingress spring-gateway
kubectl delete svc spring-gateway
kubectl delete deployment spring-gateway
kubectl delete configmap spring-gateway-config

# Certificate and secret will be cleaned up automatically by cert-manager
```

### Delete Certificate Manually

```bash
# If needed
kubectl delete certificate agentid-ellin-net-tls
kubectl delete secret agentid-ellin-net-tls
```

## Production Checklist

Before going to production:

- [ ] **Image Registry**: Use versioned tags, not `:latest`
- [ ] **Resource Limits**: Configure appropriate CPU/memory limits
- [ ] **Replicas**: Run at least 2 replicas for high availability
- [ ] **Health Checks**: Verify liveness and readiness probes work
- [ ] **TLS**: Verify cert-manager is renewing certificates
- [ ] **DNS**: Ensure DNS is properly configured and propagated
- [ ] **Monitoring**: Set up Prometheus metrics and alerts
- [ ] **Logging**: Configure centralized logging (ELK, Loki, CloudWatch)
- [ ] **Secrets**: Move sensitive config from ConfigMap to Secrets
- [ ] **Network Policies**: Restrict pod-to-pod communication
- [ ] **Pod Security**: Use security contexts and pod security standards
- [ ] **Backup**: Back up ConfigMaps and critical configuration
- [ ] **JWT Validation**: Enable `teleport.validation.enabled: true`
- [ ] **JWKS Endpoint**: Verify AgentCore can reach JWKS endpoint
- [ ] **Rate Limiting**: Consider implementing rate limiting at ingress
- [ ] **CORS**: Configure CORS if needed for browser clients

## Advanced Configuration

### Using Kubernetes Secrets

For sensitive configuration like private keys:

```bash
# Create secret from file
kubectl create secret generic spring-gateway-secrets \
  --from-literal=jwt-private-key="-----BEGIN PRIVATE KEY-----..."

# Reference in deployment
envFrom:
- secretRef:
    name: spring-gateway-secrets
```

### Network Policies

Restrict pod network access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: spring-gateway-netpol
spec:
  podSelector:
    matchLabels:
      app: spring-gateway
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: projectcontour
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 443  # AgentCore HTTPS
```

### Pod Security Standards

Apply pod security standards:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: default
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## References

- [Kubernetes Documentation](https://kubernetes.io/docs/home/)
- [Contour Ingress Controller](https://projectcontour.io/)
- [cert-manager](https://cert-manager.io/)
- [Spring Boot on Kubernetes](https://spring.io/guides/gs/spring-boot-kubernetes/)
- [TELEPORT.md](../notes/TELEPORT.md) - Teleport configuration
- [AGENTCORE.md](../notes/AGENTCORE.md) - AgentCore integration
- [BUILD.md](../notes/BUILD.md) - Docker build instructions
