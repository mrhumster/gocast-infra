NAMESPACE := go-app
SERVICES_DIR := services

.PHONY: all infra apps clean status

define LOGO
  ________       _________                  __    ________                __________      .__.__       .___
 /  _____/  ____ \_   ___ \_____    _______/  |_  \______ \   _______  __ \______   \__ __|__|  |    __| _/
/   \  ___ /  _ \/    \  \/\__  \  /  ___/\   __\  |    |  \_/ __ \  \/ /  |    |  _/  |  \  |  |   / __ | 
\    \_\  (  <_> )     \____/ __ \_\___ \  |  |    |    `   \  ___/\   /   |    |   \  |  /  |  |__/ /_/ | 
 \______  /\____/ \______  (____  /____  > |__|   /_______  /\___  >\_/    |______  /____/|__|____/\____ | 
        \/               \/     \/     \/                 \/     \/               \/                    \/ 
endef
export LOGO

all: wellcome infra apps status

wellcome:
	@echo "$$LOGO"

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
	@echo "Install MinIO"
	kubectl apply -f $(SERVICES_DIR)/stream-service/deploy/k8s/minio/.
	@echo "Wait for MinIO"
	kubectl wait --for=condition=Ready pod -l app=minio -n go-app --timeout=90s
	@echo "Configure MinIO"
	make -C $(SERVICES_DIR)/stream-service init-minio

apps:
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
	@echo "Wait transcoder-service..."
	kubectl wait --for=condition=Available deployment/transcoder-service -n $(NAMESPACE) --timeout=120s
	@echo "Deploy web-frontend"
	kubectl apply -f $(SERVICES_DIR)/web-frontend/k8s/.
	@echo "Wait web-frontend..."
	kubectl wait --for=condition=Available deployment/web-frontend -n $(NAMESPACE) --timeout=120s
	@echo "Deploy service success"

status:
	kubectl get pods -n $(NAMESPACE)
	kubectl get ingress -n $(NAMESPACE)

uninstall:
	@echo "Deleting all namespace: $(NAMESPACE)"
	kubectl delete namespace $(NAMESPACE)
