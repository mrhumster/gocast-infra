NAMESPACE := go-app
SERVICES_DIR := services

.PHONY: all render ensure-namespace apply-configmaps apply-ingresses apply-recovery apply-prometheus apply-db-migrate infra apps clean status backup restore build-web

define LOGO
  ________       _________                  __    ________                __________      .__.__       .___
 /  _____/  ____ \_   ___ \_____    _______/  |_  \______ \   _______  __ \______   \__ __|__|  |    __| _/
/   \  ___ /  _ \/    \  \/\__  \  /  ___/\   __\  |    |  \_/ __ \  \/ /  |    |  _/  |  \  |  |   / __ | 
\    \_\  (  <_> )     \____/ __ \_\___ \  |  |    |    `   \  ___/\   /   |    |   \  |  /  |  |__/ /_/ | 
 \______  /\____/ \______  (____  /____  > |__|   /_______  /\___  >\_/    |______  /____/|__|____/\____ | 
        \/               \/     \/     \/                 \/     \/               \/                    \/ 
endef
export LOGO

all: wellcome render infra apply-db-migrate apps apply-prometheus status

wellcome:
	@echo "$$LOGO"

render:
	@echo "Rendering ConfigMaps from .env"
	./scripts/render-env.sh

ensure-namespace:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

apply-configmaps:
	@echo "Apply ConfigMaps (from .env)"
	kubectl apply -f deploy/generated/configmaps/.

apply-ingresses:
	@echo "Apply Ingresses (from .env)"
	kubectl apply -f deploy/generated/ingresses/.

apply-recovery:
	@echo "Apply kindnet recovery DaemonSet (auto-heal pod-network flake)"
	kubectl apply -f deploy/k8s/kindnet-recovery/.

apply-prometheus:
	@echo "Apply Prometheus (lightweight: pod-discovery via prometheus.io annotations + MinIO)"
	kubectl apply -f deploy/k8s/prometheus/.
	@echo "Access: kubectl -n $(NAMESPACE) port-forward svc/prometheus-server 9090:9090"

apply-db-migrate:
	@echo "Run DB migrations (identity + stream)"
	kubectl apply -f $(SERVICES_DIR)/db-migrate/deploy/k8s/.
	kubectl wait --for=condition=complete job/db-migrate-identity -n $(NAMESPACE) --timeout=180s
	kubectl wait --for=condition=complete job/db-migrate-stream -n $(NAMESPACE) --timeout=180s
	@echo "DB migrations done"

infra: ensure-namespace apply-recovery
	@echo "Install cert-manager"
	make -C $(SERVICES_DIR)/identity-service deploy-certmanager
	@echo "Install ingress controller"
	make -C $(SERVICES_DIR)/identity-service deploy-ingress-nginx
	@echo "Install Postgresql"
	make -C $(SERVICES_DIR)/identity-service deploy-postgres
	@echo "Install Redis"
	make -C $(SERVICES_DIR)/identity-service deploy-redis
	@echo "Install MinIO"
	kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/minio/.
	@echo "Wait for MinIO"
	kubectl wait --for=condition=Ready pod -l app=minio -n go-app --timeout=90s
	@echo "Configure MinIO"
	make -C $(SERVICES_DIR)/stream-service init-minio
	@echo "Deploy KEDA"
	make -C $(SERVICES_DIR)/transcoder-service keda-deploy
	@echo "Apply gRPC mTLS certificates (requires ca-issuer)"
	kubectl apply -f $(SERVICES_DIR)/identity-service/deploy/k8s/grpc-mtls/grpc-certificates.yaml
	kubectl -n $(NAMESPACE) wait --for=condition=Ready certificate grpc-identity-tls grpc-stream-tls grpc-thumbnail-tls grpc-transcoder-tls --timeout=120s

apps: ensure-namespace apply-configmaps apply-ingresses
	@echo "Deploy identity-service"
	kubectl apply -f $(SERVICES_DIR)/identity-service/deploy/k8s/base/.
	@echo "HPA"
	kubectl apply -f $(SERVICES_DIR)/identity-service/deploy/k8s/scaling/hpa.yaml
	kubectl wait --for=condition=Available deployment/identity-service -n $(NAMESPACE) --timeout=120s
	@echo "Deploy stream-service"
	kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/base/.
	kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/scaling/.
	@echo "Wait stream-service..."
	kubectl wait --for=condition=Available deployment/stream-service -n $(NAMESPACE) --timeout=120s
	@echo "Deploy transcoder-service"
	kubectl apply -f $(SERVICES_DIR)/transcoder-service/deploy/k8s/transcoder/.
	kubectl apply -f $(SERVICES_DIR)/transcoder-service/deploy/k8s/keda/.
	@echo "Wait transcoder-service..."
	kubectl wait --for=condition=Available deployment/transcoder-service -n $(NAMESPACE) --timeout=120s
	@echo "Deploy thumbnail-service"
	kubectl apply -f $(SERVICES_DIR)/thumbnail-service/deploy/k8s/thumbnail/.
	kubectl apply -f $(SERVICES_DIR)/thumbnail-service/deploy/k8s/keda/.
	@echo "Wait thumbnail-service..."
	kubectl wait --for=condition=Available deployment/thumbnail-service -n $(NAMESPACE) --timeout=120s
	@echo "Deploy web-frontend"
	kubectl apply -f $(SERVICES_DIR)/web-frontend/k8s/.
	@echo "Wait web-frontend..."
	kubectl wait --for=condition=Available deployment/web-frontend -n $(NAMESPACE) --timeout=120s
	@echo "Deploy service success"

status:
	kubectl get pods -n $(NAMESPACE)
	kubectl get ingress -n $(NAMESPACE)

# ------------------------------------------------------------------
# Backup / Restore (стратегия restore: пережить kind delete)
# ------------------------------------------------------------------
backup:
	./scripts/backup.sh

restore:
	./scripts/restore.sh

# ------------------------------------------------------------------
# Web-frontend: сборка с build-args из единого .env
# ------------------------------------------------------------------
build-web:
	@echo "Building web-frontend with URLs from .env"
	set -a && . ./.env && set +a; \
	docker build \
		--build-arg VITE_API_URL=$$VITE_API_URL \
		--build-arg VITE_WS_URL=$$VITE_WS_URL \
		--build-arg VITE_HLS_URL=$$VITE_HLS_URL \
		--build-arg VITE_STORAGE_URL=$$VITE_STORAGE_URL \
		-t xomrkob/web-frontend:latest \
		$(SERVICES_DIR)/web-frontend
	docker push xomrkob/web-frontend:latest

uninstall:
	@echo "Deleting all namespace: $(NAMESPACE)"
	kubectl delete namespace $(NAMESPACE)
