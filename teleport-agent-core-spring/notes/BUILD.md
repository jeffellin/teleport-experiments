# Building and Deploying Docker Images

This guide covers building Docker images for the Spring Cloud Gateway and deploying to Kubernetes.

**Status**: ✅ **Working and Deployed**

## Overview

The gateway is packaged as a Docker image and deployed to Kubernetes. The build process supports:

- ✅ Native platform builds for local testing (ARM/x86)
- ✅ Cross-platform builds for Kubernetes deployment (amd64)
- ✅ Multi-platform builds for mixed environments (amd64 + arm64)
- ✅ Docker Hub registry integration

## Prerequisites

### Docker Buildx Setup

For multi-platform builds, ensure Docker buildx is set up:

```bash
# Check if buildx is available
docker buildx version

# Create a new builder (one-time setup)
docker buildx create --name multiplatform --use
docker buildx inspect --bootstrap

# Verify builder is running
docker buildx ls
```

### Docker Hub Authentication

```bash
# Login to Docker Hub
docker login

# Or specify username
docker login -u your-username
```

## Build Commands

All build commands are available in the Makefile for convenience.

### For Local Development (Native Platform)

Build for your current platform (faster, no cross-compilation):

```bash
# Build for your current platform using Makefile
make docker-build

# Or directly with Docker
docker build -t spring-gateway:latest .

# Test locally
docker run -p 8082:8080 spring-gateway:latest
```

### For Kubernetes (x86/amd64)

If you're on Apple Silicon (M1/M2/M3/M4) but deploying to x86 Kubernetes nodes:

```bash
# Build for x86/amd64 and load into local Docker
make docker-build-x86

# Or directly with Docker buildx
docker buildx build --platform linux/amd64 -t spring-gateway:latest --load .
```

**Note**: The `--load` flag loads the image into your local Docker daemon so you can:
- Test with `docker run`
- Push to a registry with `docker push`
- Load into kind/minikube with `kind load docker-image`

### For Multi-Platform (x86 + ARM)

Build for both platforms (useful for mixed Kubernetes clusters):

```bash
# Build for both platforms (requires push to registry)
make docker-build-multi

# Or directly with Docker buildx
docker buildx build --platform linux/amd64,linux/arm64 -t spring-gateway:latest --push .
```

**Important**: Multi-platform builds cannot be loaded into the local Docker daemon. They must be pushed directly to a registry.

## Push to Docker Hub

The project uses Docker Hub registry: `ellinj/spring-agent-gateway`

### Push x86 Image

```bash
# Build and tag for Docker Hub
make docker-build-x86
docker tag spring-gateway:latest ellinj/spring-agent-gateway:latest
docker push ellinj/spring-agent-gateway:latest

# Or with versioned tag
docker tag spring-gateway:latest ellinj/spring-agent-gateway:v1.2.0
docker push ellinj/spring-agent-gateway:v1.2.0
```

### Push Multi-Platform Image

```bash
# Build and push both platforms to Docker Hub
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ellinj/spring-agent-gateway:latest \
  -t ellinj/spring-agent-gateway:v1.2.0 \
  --push .
```

## Deployment Workflows

### Local Development Workflow

```bash
# 1. Build for your platform
make docker-build

# 2. Run locally
docker run -p 8082:8080 \
  -e AGENTCORE_ENDPOINT=https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com \
  -e AGENTCORE_ISSUER=https://agentid.ellin.net \
  spring-gateway:latest

# 3. Start Teleport app service (in another terminal)
./start-with-teleport.sh <your-token>

# 4. Test
tsh app login agentid
curl \
  --cert ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.crt \
  --key ~/.tsh/keys/ellinj.teleport.sh/jeffrey.ellin@goteleport.com-app/ellinj.teleport.sh/agentid.key \
  https://agentid.ellinj.teleport.sh/test/echo
```

### Production Kubernetes Workflow

```bash
# 1. Build x86 image for Kubernetes
make docker-build-x86

# 2. Tag for Docker Hub
docker tag spring-gateway:latest ellinj/spring-agent-gateway:v1.2.0

# 3. Push to Docker Hub
docker push ellinj/spring-agent-gateway:v1.2.0

# 4. Update Kubernetes deployment
kubectl set image deployment/spring-gateway \
  spring-gateway=ellinj/spring-agent-gateway:v1.2.0

# 5. Verify deployment
kubectl rollout status deployment/spring-gateway
kubectl get pods -l app=spring-gateway
kubectl logs -l app=spring-gateway -f
```

### Alternative: Direct Apply

```bash
# 1. Build and push
make docker-build-x86
docker tag spring-gateway:latest ellinj/spring-agent-gateway:latest
docker push ellinj/spring-agent-gateway:latest

# 2. Update k8s/deployment.yaml with new image tag if needed

# 3. Apply Kubernetes manifests
kubectl apply -f k8s/

# 4. Verify
kubectl get all -l app=spring-gateway
```

## Verify Image

### Check Platform Architecture

```bash
# Inspect local image
docker inspect spring-gateway:latest | grep Architecture

# Or use buildx
docker buildx imagetools inspect spring-gateway:latest
```

Expected output for x86:
```json
"Architecture": "amd64"
```

### Check Registry Image

```bash
# Inspect image in Docker Hub
docker buildx imagetools inspect ellinj/spring-agent-gateway:latest
```

Expected output for multi-platform:
```
Name:      docker.io/ellinj/spring-agent-gateway:latest
MediaType: application/vnd.docker.distribution.manifest.list.v2+json
Digest:    sha256:abc123...

Manifests:
  Name:      docker.io/ellinj/spring-agent-gateway:latest@sha256:def456...
  MediaType: application/vnd.docker.distribution.manifest.v2+json
  Platform:  linux/amd64

  Name:      docker.io/ellinj/spring-agent-gateway:latest@sha256:ghi789...
  MediaType: application/vnd.docker.distribution.manifest.v2+json
  Platform:  linux/arm64
```

## Testing Builds

### Test Locally with Docker

```bash
# Build
make docker-build

# Run with environment variables
docker run -p 8082:8080 \
  -e AGENTCORE_ENDPOINT=https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com \
  -e AGENTCORE_ENDPOINT_WS=wss://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com \
  -e AGENTCORE_ENDPOINT_MCP=https://your-gateway.bedrock-agentcore.us-east-2.amazonaws.com \
  -e AGENTCORE_ISSUER=https://agentid.ellin.net \
  -e AGENTCORE_AUDIENCE=agentcore-gateway \
  spring-gateway:latest

# Test health endpoint
curl http://localhost:8082/actuator/health
```

### Test with Kind (Local Kubernetes)

```bash
# Create kind cluster
kind create cluster --name test-gateway

# Load image into kind
make docker-build-x86
kind load docker-image spring-gateway:latest --name test-gateway

# Deploy to kind
kubectl apply -f k8s/

# Port-forward for testing
kubectl port-forward svc/spring-gateway 8082:8080

# Test
curl http://localhost:8082/actuator/health
```

## Dockerfile Overview

The Dockerfile uses multi-stage builds for efficiency:

### Stage 1: Build (Maven)

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY ../pom.xml .
COPY ../src ./src
RUN mvn clean package -DskipTests
```

### Stage 2: Runtime (JDK 21)
```dockerfile
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**Benefits**:
- ✅ Smaller final image (only JRE, no Maven)
- ✅ Faster builds with layer caching
- ✅ Reproducible builds

## Troubleshooting

### Error: "multiple platforms feature is currently not supported"

You need to use buildx:

```bash
docker buildx create --name multiplatform --use
docker buildx inspect --bootstrap
```

### Error: "failed to solve: failed to load cache"

Clear Docker buildx cache:

```bash
docker buildx prune -a

# Or remove and recreate builder
docker buildx rm multiplatform
docker buildx create --name multiplatform --use
```

### Image runs on Mac but crashes on Kubernetes

**Cause**: You built for ARM (Apple Silicon) instead of x86.

**Fix**:
```bash
# Build for x86/amd64
make docker-build-x86

# Verify platform
docker inspect spring-gateway:latest | grep Architecture
# Should show: "Architecture": "amd64"
```

### Cannot load multi-platform image

**Cause**: Multi-platform builds can't be loaded into local Docker daemon.

**Options**:

1. **For local use**: Build single platform with `--load`:
   ```bash
   docker buildx build --platform linux/amd64 -t spring-gateway:latest --load .
   ```

2. **For registry**: Push multi-platform:
   ```bash
   docker buildx build --platform linux/amd64,linux/arm64 \
     -t ellinj/spring-agent-gateway:latest --push .
   ```

### Kubernetes pulls old image

**Cause**: Image tag hasn't changed (e.g., using `:latest`).

**Fix**:

1. **Use versioned tags**:
   ```bash
   docker tag spring-gateway:latest ellinj/spring-agent-gateway:v1.2.1
   docker push ellinj/spring-agent-gateway:v1.2.1
   kubectl set image deployment/spring-gateway spring-gateway=ellinj/spring-agent-gateway:v1.2.1
   ```

2. **Or force pull**:
   ```yaml
   # k8s/deployment.yaml
   spec:
     containers:
     - name: spring-gateway
       image: ellinj/spring-agent-gateway:latest
       imagePullPolicy: Always  # Force pull on every deploy
   ```

3. **Or restart deployment**:
   ```bash
   kubectl rollout restart deployment/spring-gateway
   ```

### Build fails with "Could not resolve dependencies"

**Cause**: Maven dependency resolution issues.

**Fix**:
```bash
# Clear local Maven cache
rm -rf ~/.m2/repository

# Rebuild
make docker-build
```

## Platform Detection in Dockerfile

The Dockerfile uses build arguments for platform-aware builds:

- `BUILDPLATFORM` - Platform of the build machine (e.g., `linux/arm64` on Mac M1)
- `TARGETPLATFORM` - Platform of the target image (e.g., `linux/amd64` for Kubernetes)

This allows:
- Maven to run on your native platform (faster)
- Final image to be built for the target platform (correct architecture)

## Image Size Optimization

Current image size: ~300MB (JRE 21 + Spring Boot app)

**Optimization tips**:

1. **Use Alpine base** (smaller, but less compatible):
   ```dockerfile
   FROM eclipse-temurin:21-jre-alpine
   ```

2. **Use jlink for custom JRE** (advanced):
   ```dockerfile
   RUN jlink --add-modules java.base,java.logging,java.sql \
     --strip-debug --no-man-pages --no-header-files \
     --compress=2 --output /javaruntime
   ```

3. **Layer caching**: Dependencies are cached separately from source code, speeding up rebuilds.

## Production Checklist

Before deploying to production:

- [ ] Build for correct platform (amd64 for x86 clusters)
- [ ] Tag with version number (not just `:latest`)
- [ ] Push to registry (Docker Hub or private registry)
- [ ] Update Kubernetes deployment with versioned tag
- [ ] Verify image platform matches Kubernetes nodes
- [ ] Test health endpoint after deployment
- [ ] Check pod logs for startup errors
- [ ] Verify JWKS endpoint is accessible
- [ ] Test JWT transformation with `/test/echo`
- [ ] Monitor resource usage (CPU/memory)

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Build and Push Docker Image

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Login to Docker Hub
        uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ellinj/spring-agent-gateway:latest
            ellinj/spring-agent-gateway:${{ github.ref_name }}
```

## References

- [Docker Buildx Documentation](https://docs.docker.com/buildx/working-with-buildx/)
- [Multi-platform Images](https://docs.docker.com/build/building/multi-platform/)
- [Spring Boot Docker Guide](https://spring.io/guides/topicals/spring-boot-docker/)
- [Kubernetes Image Best Practices](https://kubernetes.io/docs/concepts/containers/images/)
