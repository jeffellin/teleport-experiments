# Kubernetes Deployment

This directory contains Kubernetes manifests for deploying the Spring Gateway to Kubernetes with Ingress.

## Prerequisites

- Kubernetes cluster (1.25+)
- kubectl configured
- Ingress Controller installed (nginx, traefik, etc.)
- cert-manager installed with `letsencrypt-prod` ClusterIssuer
- Docker image built and available

## Files

- `configmap.yaml` - Configuration for the gateway
- `deployment.yaml` - Deployment manifest
- `service.yaml` - Service to expose the deployment
- `ingress.yaml` - Ingress resource (routes to agentid.ellin.net)
- `kustomization.yaml` - Kustomize configuration

## Quick Start

### 1. Build Docker Image

```bash
# For Kubernetes (x86/amd64 architecture)
make docker-build-x86

# Or if building on Apple Silicon for x86 Kubernetes nodes:
docker buildx build --platform linux/amd64 -t spring-gateway:latest --load .

# To push to a registry:
make docker-push REGISTRY=your-registry.com

# Or manually:
docker buildx build --platform linux/amd64 \
  -t your-registry.com/spring-gateway:latest \
  --push .
```

**Important:** If you're on Apple Silicon (M1/M2/M3), you must build for x86/amd64 architecture for most Kubernetes clusters. See [BUILD.md](../BUILD.md) for more details.

### 2. Configure DNS

Before deploying, point `agentid.ellin.net` to your Ingress Controller's LoadBalancer:

```bash
# Get LoadBalancer IP/hostname (adjust namespace if needed)
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide

# Or for other ingress controllers, find the service:
kubectl get svc -A | grep -i ingress

# Create DNS A record or CNAME
# agentid.ellin.net -> <LoadBalancer IP or hostname>
```

**Note:** The TLS certificate will be automatically provisioned by cert-manager when you deploy. The certificate will be issued by Let's Encrypt using the `letsencrypt-prod` ClusterIssuer (configured via annotation in `ingress.yaml`).

### 3. Update Configuration

Edit `configmap.yaml` and update:

- `teleport.jwks-uri` - Your Teleport JWKS URI
- `teleport.validation.enabled` - Set to `true` for production
- `agentcore.endpoint` - AgentCore endpoint URL
- `agentcore.issuer` - Should match your domain: `https://agentid.ellin.net`

### 4. Deploy

```bash
# Deploy using kubectl
kubectl apply -k k8s/

# Or deploy individual files
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

### 5. Verify Deployment

```bash
# Check deployment status
kubectl get deployment spring-gateway
kubectl get pods -l app=spring-gateway

# Check service
kubectl get svc spring-gateway

# Check Ingress
kubectl get ingress spring-gateway
kubectl describe ingress spring-gateway

# Check certificate (cert-manager - created automatically by ingress)
kubectl get certificate
kubectl describe certificate agentid-ellin-net-tls

# View logs
kubectl logs -l app=spring-gateway -f

# Test health endpoint (via port-forward)
kubectl port-forward svc/spring-gateway 8080:80
curl http://localhost:8080/actuator/health
```

## Testing

Once deployed and DNS is configured:

```bash
# Test health endpoint
curl https://agentid.ellin.net/actuator/health

# Test JWKS endpoint
curl https://agentid.ellin.net/.well-known/jwks.json

# Test with JWT
export JWT="your-jwt-token"
curl -H "Authorization: Bearer $JWT" https://agentid.ellin.net/test/echo
```

## Configuration Updates

To update configuration:

```bash
# Edit configmap
kubectl edit configmap spring-gateway-config

# Or apply updated file
kubectl apply -f k8s/configmap.yaml

# Restart pods to pick up changes
kubectl rollout restart deployment spring-gateway
```

## Scaling

```bash
# Scale replicas
kubectl scale deployment spring-gateway --replicas=3

# Or update deployment.yaml and apply
```

## Monitoring

```bash
# Watch pod status
kubectl get pods -l app=spring-gateway -w

# View logs
kubectl logs -l app=spring-gateway -f --tail=100

# Describe deployment
kubectl describe deployment spring-gateway
```

## Troubleshooting

### Pods not starting

```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Ingress not working

```bash
# Check Ingress status
kubectl get ingress spring-gateway
kubectl describe ingress spring-gateway

# Check Ingress controller logs (adjust namespace for your ingress controller)
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller -f

# Verify the ingress class
kubectl get ingressclass
```

### TLS issues

```bash
# Check certificate (created automatically by cert-manager from ingress annotation)
kubectl get certificate
kubectl describe certificate agentid-ellin-net-tls

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f

# Check certificate request
kubectl get certificaterequest

# Check secret
kubectl get secret agentid-ellin-net-tls
kubectl describe secret agentid-ellin-net-tls
```

### WebSocket not working

```bash
# Verify WebSocket annotations in ingress
kubectl get ingress spring-gateway -o yaml | grep -A5 websocket

# Test WebSocket connection (using wscat)
wscat -c "wss://agentid.ellin.net/ws" -H "Authorization: Bearer $JWT"
```

## Cleanup

```bash
# Delete all resources
kubectl delete -k k8s/

# Or delete individually
kubectl delete ingress spring-gateway
kubectl delete svc spring-gateway
kubectl delete deployment spring-gateway
kubectl delete configmap spring-gateway-config

# Certificate will be cleaned up automatically by cert-manager
```

## Production Considerations

1. **Image Registry**: Use a private container registry
2. **Resource Limits**: Adjust CPU/memory limits based on load
3. **Replicas**: Run at least 2 replicas for high availability
4. **TLS**: Use cert-manager with Let's Encrypt for automatic certificate renewal
5. **Secrets**: Store sensitive config in Kubernetes Secrets, not ConfigMaps
6. **Monitoring**: Add Prometheus metrics and configure alerts
7. **Logging**: Configure centralized logging (ELK, Loki, etc.)
8. **Network Policies**: Restrict pod-to-pod communication
9. **Pod Security**: Use security contexts and pod security policies