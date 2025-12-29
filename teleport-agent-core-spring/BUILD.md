# Building Docker Images

This guide covers building Docker images for different platforms.

## Prerequisites

For multi-platform builds, ensure Docker buildx is set up:

```bash
# Check if buildx is available
docker buildx version

# Create a new builder (one-time setup)
docker buildx create --name multiplatform --use
docker buildx inspect --bootstrap
```

## Build Commands

### For Local Development (Native Platform)

```bash
# Build for your current platform (Mac ARM, x86, etc.)
make docker-build

# Or directly:
docker build -t spring-gateway:latest .
```

### For Kubernetes (x86/amd64)

If you're on Apple Silicon (M1/M2/M3) but deploying to x86 Kubernetes nodes:

```bash
# Build for x86/amd64 and load into local Docker
make docker-build-x86

# Or directly:
docker buildx build --platform linux/amd64 -t spring-gateway:latest --load .
```

**Note:** The `--load` flag loads the image into your local Docker daemon so you can use it with `docker run` or push it.

### For Multi-Platform (x86 + ARM)

Build for both platforms (useful if you have mixed Kubernetes nodes):

```bash
# Build for both platforms (won't load locally)
make docker-build-multi

# Or directly:
docker buildx build --platform linux/amd64,linux/arm64 -t spring-gateway:latest .
```

**Note:** Multi-platform builds cannot be loaded into the local Docker daemon. They must be pushed to a registry.

## Push to Registry

### Push x86 Image

```bash
# Build and push x86 image to registry
make docker-push REGISTRY=your-registry.com

# Or directly:
docker buildx build --platform linux/amd64 \
  -t your-registry.com/spring-gateway:latest \
  --push .
```

### Push Multi-Platform Image

```bash
# Build and push both platforms to registry
make docker-push-multi REGISTRY=your-registry.com

# Or directly:
docker buildx build --platform linux/amd64,linux/arm64 \
  -t your-registry.com/spring-gateway:latest \
  --push .
```

## Verify Platform

After building, verify the image platform:

```bash
# Inspect image
docker inspect spring-gateway:latest | grep Architecture

# Or use buildx
docker buildx imagetools inspect spring-gateway:latest
```

For registry images:

```bash
docker buildx imagetools inspect your-registry.com/spring-gateway:latest
```

## Common Workflows

### Building for Local Testing

```bash
# Build and run locally (native platform)
make docker-build
docker run -p 8080:8080 spring-gateway:latest
```

### Building for Kubernetes Deployment

```bash
# Option 1: Build x86 and deploy to local k8s (e.g., kind, minikube)
make dev-deploy

# Option 2: Build and push to registry, then deploy
make docker-push REGISTRY=your-registry.com
kubectl apply -k k8s/
```

### Update Deployment Image

If using a registry, update the image in `k8s/kustomization.yaml`:

```yaml
images:
- name: spring-gateway
  newName: your-registry.com/spring-gateway
  newTag: v1.0.0
```

## Troubleshooting

### Error: "multiple platforms feature is currently not supported"

You need to use buildx:

```bash
docker buildx create --name multiplatform --use
```

### Error: "failed to solve: failed to load cache"

Clear Docker buildx cache:

```bash
docker buildx prune -a
```

### Image runs on Mac but not on Kubernetes

You likely built for ARM (Apple Silicon) instead of x86. Use:

```bash
make docker-build-x86
```

### Cannot load multi-platform image

Multi-platform builds can't be loaded locally. Either:
1. Build only for your target platform with `--load`
2. Push to a registry instead

```bash
# For local use (single platform)
docker buildx build --platform linux/amd64 -t spring-gateway:latest --load .

# For registry (can be multi-platform)
docker buildx build --platform linux/amd64,linux/arm64 -t registry/spring-gateway:latest --push .
```

## Platform Detection in Dockerfile

The Dockerfile uses build arguments for platform-aware builds:

- `BUILDPLATFORM` - Platform of the build machine
- `TARGETPLATFORM` - Platform of the target image

This allows Maven to run on your native platform (faster) while creating an image for the target platform.