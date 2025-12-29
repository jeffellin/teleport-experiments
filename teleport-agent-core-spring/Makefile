.PHONY: help build test docker-build docker-push k8s-deploy k8s-delete k8s-logs clean

IMAGE_NAME ?= spring-gateway
IMAGE_TAG ?= latest
REGISTRY ?= ellinj
NAMESPACE ?= default

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

build: ## Build the application with Maven
	./mvnw clean package

test: ## Run tests
	./mvnw test

docker-build: ## Build Docker image for native platform
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-build-x86: ## Build Docker image for x86/amd64 (for Kubernetes)
	docker buildx build --platform linux/amd64 -t $(IMAGE_NAME):$(IMAGE_TAG) --load .

docker-build-multi: ## Build Docker image for multiple platforms
	docker buildx build --platform linux/amd64,linux/arm64 -t $(IMAGE_NAME):$(IMAGE_TAG) .

docker-push: ## Build and push Docker image to registry (x86/amd64)
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: REGISTRY not set. Usage: make docker-push REGISTRY=your-registry.com"; \
		exit 1; \
	fi
	docker buildx build --platform linux/amd64 \
		-t $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG) \
		--push .

docker-push-multi: ## Build and push multi-platform image to registry
	@if [ -z "$(REGISTRY)" ]; then \
		echo "Error: REGISTRY not set. Usage: make docker-push-multi REGISTRY=your-registry.com"; \
		exit 1; \
	fi
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG) \
		--push .

k8s-deploy: ## Deploy to Kubernetes
	kubectl apply -f k8s/ -n $(NAMESPACE)

k8s-delete: ## Delete from Kubernetes
	kubectl delete -f k8s/ -n $(NAMESPACE)

k8s-restart: ## Restart deployment
	kubectl rollout restart deployment spring-gateway -n $(NAMESPACE)

k8s-status: ## Check deployment status
	@echo "=== Deployment ==="
	kubectl get deployment spring-gateway -n $(NAMESPACE)
	@echo ""
	@echo "=== Pods ==="
	kubectl get pods -l app=spring-gateway -n $(NAMESPACE)
	@echo ""
	@echo "=== Service ==="
	kubectl get svc spring-gateway -n $(NAMESPACE)
	@echo ""
	@echo "=== Ingress ==="
	kubectl get ingress spring-gateway -n $(NAMESPACE)
	@echo ""
	@echo "=== Certificate ==="
	kubectl get certificate -n $(NAMESPACE)

k8s-logs: ## View logs
	kubectl logs -l app=spring-gateway -n $(NAMESPACE) -f --tail=100

k8s-describe: ## Describe deployment
	kubectl describe deployment spring-gateway -n $(NAMESPACE)

k8s-port-forward: ## Port forward to local
	kubectl port-forward svc/spring-gateway 8080:80 -n $(NAMESPACE)

clean: ## Clean build artifacts
	./mvnw clean
	rm -rf target/

run: ## Run locally with Maven
	./mvnw spring-boot:run

teleport-start: ## Start Teleport app service (requires TOKEN=your-token)
	@if [ -z "$(TOKEN)" ]; then \
		echo "Error: TOKEN not set. Usage: make teleport-start TOKEN=your-token"; \
		exit 1; \
	fi
	@mkdir -p ./teleport-data
	teleport start \
		--config=teleport-app.yml \
		--token=$(TOKEN) \
		--app-name=agentid \
		--app-uri=http://localhost:8082 \
		--labels=env=dev,app=spring-gateway \
		--debug

all: build docker-build ## Build everything

# Development shortcuts
dev-deploy: docker-build-x86 k8s-deploy ## Build (x86) and deploy to k8s
dev-redeploy: docker-build-x86 k8s-restart ## Rebuild (x86) image and restart pods