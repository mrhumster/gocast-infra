NAMESPACE := go-app
SERVICES_DIR := services

.PHONY: all infra apps clean status

all: infra apps status

infra:
				@echo "Create namespace"
				kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
				@echo "Install cert-manager"
				make -C $(SERVICES_DIR)/identity-service deploy-certmanager
				@echo "Install ingress controller"
				make -C $(SERVICES_DIR)/identity-service deploy-ingress-nginx
				@echo "Install Postgresql"
				make -C $(SERVICES_DIR)/identity-service deploy-postgres
				@echo "Install Redis"
				make -C $(SERVICES_DIR)/identity-service deploy-redis
				@echo "Install Minio"
				kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/minio/.
				@echo "Configure Minio"
				make -C $(SERVICES_DIR)/stream-service init-minio

apps:
				@echo "Deploy identity-service"
				kubectl apply -f $(SERVICES_DIR)/identity-service/deploy/k8s/base/.
				@echo "HPA"
				kubectl apply -f $(SERVICES_DIR)/identity-service/deploy/k8s/scaling/hpa.yaml
				@echo "Build last version"
				make -C $(SERVICES_DIR)/identity-service
				@echo "Wait identity-service..."
				kubectl wait --for=condition=Available depployment/identity-service -n $(NAMESPACE) --timeout=120s
				@echo "Deploy stream-service"
				kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/base/.
				kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/scaling/.
				@echo "Build last version"
				make -C $(SERVICES_DIR)/stream-service
				@echo "Wait stream-service..."
				kubectl wait --for=condition=Available depployment/stream-service -n $(NAMESPACE) --timeout=120s
				@echo "Deploy transcoder-service"
				kubectl apply -f $(SERVICES_DIR)/transcoder-service/deploy/k8s/transcoder/.
				@echo "Build last version"
				make -C $(SERVICES_DIR)/transcoder-service
				@echo "Wait transcoder-service..."
				kubectl wait --for=condition=Available depployment/transcoder-service -n $(NAMESPACE) --timeout=120s
				@echo "Deploy web-frontend"
				kubectl apply -f $(SERVICES_DIR)/web-frontend/k8s/.
				@echo "Build last version"
				pnpm run k8s:build 
				@echo "Wait web-frontend..."
				kubectl wait --for=condition=Available depployment/web-frontend -n $(NAMESPACE) --timeout=120s
				@echo "Deploy service success"

status:
				kubectl get pods -n $(NAMESPACE)
				kubectl get ingress -n $(NAMESPACE)
