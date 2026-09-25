ANSIBLE_DIR ?= ansible
PLAYBOOK_DIR ?= $(ANSIBLE_DIR)/playbooks
INVENTORY_DIR ?= $(ANSIBLE_DIR)/inventories
ANSIBLE_CONFIG_FILE ?= $(ANSIBLE_DIR)/ansible.cfg
PYTHON ?= python3
VENV_DIR ?= .venv
VENV_BIN ?= $(VENV_DIR)/bin
ANSIBLE ?= $(VENV_BIN)/ansible
ANSIBLE_PLAYBOOK ?= $(VENV_BIN)/ansible-playbook
ANSIBLE_GALAXY ?= $(VENV_BIN)/ansible-galaxy
ANSIBLE_LINT ?= $(VENV_BIN)/ansible-lint
INVENTORY ?= $(INVENTORY_DIR)/production.ini
PREPARE_PLAYBOOK ?= $(PLAYBOOK_DIR)/playbook.yml
DEPLOY_PLAYBOOK ?= $(PLAYBOOK_DIR)/deploy.yml
PROMETHEUS_PLAYBOOK ?= $(PLAYBOOK_DIR)/prometheus.yml
PROMETHEUS_CHECK_PLAYBOOK ?= $(PLAYBOOK_DIR)/prometheus-check.yml
LOKI_CHECK_PLAYBOOK ?= $(PLAYBOOK_DIR)/loki-check.yml
GRAFANA_CHECK_PLAYBOOK ?= $(PLAYBOOK_DIR)/grafana-check.yml
REQUIREMENTS_FILE ?= requirements.yml
PYTHON_REQUIREMENTS_FILE ?= requirements-dev.txt
APP_GROUP ?= app
MONITORING_GROUP ?= monitoring
APP_URL ?= https://uit14.ru
MANAGEMENT_BACKEND_PORT ?= 19090
MONITORING_PROXY_PORT ?= 9090
NODE_EXPORTER_PORT ?= 9100
NGINX_EXPORTER_PORT ?= 9113
CONTAINER_NAME ?= project-devops-deploy
NGINX_EXPORTER_CONTAINER_NAME ?= nginx-prometheus-exporter
PROMETHEUS_CONTAINER_NAME ?= prometheus
LOKI_CONTAINER_NAME ?= loki
PROMTAIL_CONTAINER_NAME ?= promtail
GRAFANA_CONTAINER_NAME ?= grafana
IMAGE_TAG ?=
TERRAFORM ?= terraform
TERRAFORM_DIR ?= terraform
TF_VAR_FILE ?= terraform.tfvars
TF_PLAN_FILE ?= project-319.tfplan
TF_STATE_BUCKET ?=
KUBECTL ?= kubectl
K8S_DIR ?= k8s
K8S_NAMESPACE ?= bulletins
K8S_DEPLOYMENT ?= bulletins
K8S_SERVICE ?= bulletins
K8S_PUBLIC_SERVICE ?= bulletins-public
K8S_IMAGE_REPOSITORY ?= cr.yandex/crphrkv4imihhuukiv7q/project-devops-deploy
K8S_IMAGE_TAG ?= a100ed36995989034cee26c2cfd9e1558201bdaa
K8S_IMAGE ?= $(K8S_IMAGE_REPOSITORY):$(K8S_IMAGE_TAG)
K8S_NEW_IMAGE ?=
K8S_PUBLIC_CHECK_REQUESTS ?= 20
K8S_DISTRIBUTION_REQUESTS ?= 60
K8S_ROLLOUT_TIMEOUT ?= 300s

export ANSIBLE_CONFIG := $(abspath $(ANSIBLE_CONFIG_FILE))
export ANSIBLE_HOME := $(abspath .ansible)

.PHONY: install vault-encrypt lint syntax test ping smoke prepare deploy rollback check health metrics \
	node-metrics nginx-status nginx-metrics nginx-exporter-logs logs \
	monitoring-deploy prometheus-check loki-check \
	prometheus-config-check prometheus-logs loki-logs promtail-logs \
	grafana-update grafana-check \
	grafana-logs grafana-alerting-check grafana-alert-test \
	grafana-alert-test-reset \
	terraform-fmt terraform-init terraform-validate terraform-plan \
	terraform-apply terraform-output terraform-kubeconfig terraform-destroy \
	k8s-secret k8s-deploy k8s-status k8s-check k8s-public-url \
	k8s-public-check k8s-rollout-check k8s-port-forward k8s-logs

install:
	$(PYTHON) -m venv $(VENV_DIR)
	$(VENV_BIN)/python -m pip install --disable-pip-version-check --requirement $(PYTHON_REQUIREMENTS_FILE)
	SSL_CERT_FILE="$$($(VENV_BIN)/python -m certifi)" $(ANSIBLE_GALAXY) install -r $(REQUIREMENTS_FILE)

vault-encrypt:
	$(VENV_BIN)/ansible-vault encrypt_string --ask-vault-pass --prompt

lint:
	$(ANSIBLE_LINT) --config-file .ansible-lint ansible/

syntax:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PREPARE_PLAYBOOK) --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(DEPLOY_PLAYBOOK) --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_PLAYBOOK) --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_CHECK_PLAYBOOK) --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(LOKI_CHECK_PLAYBOOK) --syntax-check
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(GRAFANA_CHECK_PLAYBOOK) --syntax-check

test: lint syntax

ping:
	$(ANSIBLE) -i $(INVENTORY) all -m ansible.builtin.ping

smoke:
	$(MAKE) ping
	$(MAKE) check
	$(MAKE) health
	$(MAKE) prometheus-config-check
	$(MAKE) prometheus-check
	$(MAKE) grafana-check
	$(MAKE) loki-check

prepare:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PREPARE_PLAYBOOK)

deploy:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(DEPLOY_PLAYBOOK) --ask-vault-pass $(if $(IMAGE_TAG),--extra-vars "deploy_image_tag=$(IMAGE_TAG)",)

rollback:
	@test -n "$(IMAGE_TAG)" || { echo "Usage: make rollback IMAGE_TAG=<full-commit-sha>"; exit 1; }
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(DEPLOY_PLAYBOOK) --ask-vault-pass --extra-vars "deploy_image_tag=$(IMAGE_TAG)"

check:
	curl --fail --silent --show-error --location --output /dev/null "$(APP_URL)/"
	curl --fail --silent --show-error --location --output /dev/null "$(APP_URL)/manifest.json"
	curl --fail --silent --show-error --location --output /dev/null "$(APP_URL)/api/bulletins"
	@echo "Application page, static manifest and REST endpoint are available at $(APP_URL)"

health:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.uri -a "url=http://127.0.0.1:$(MANAGEMENT_BACKEND_PORT)/actuator/health/readiness method=GET status_code=200 timeout=5"

metrics:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.uri -a "url=http://127.0.0.1:$(MANAGEMENT_BACKEND_PORT)/actuator/prometheus method=GET status_code=200 timeout=5"

node-metrics:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.uri -a "url=http://127.0.0.1:$(NODE_EXPORTER_PORT)/metrics method=GET status_code=200 timeout=5"

nginx-status:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.uri -a "url=http://127.0.0.1:$(MONITORING_PROXY_PORT)/nginx_status method=GET status_code=200 return_content=true timeout=5"

nginx-metrics:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.uri -a "url=http://127.0.0.1:$(NGINX_EXPORTER_PORT)/metrics method=GET status_code=200 timeout=5"

nginx-exporter-logs:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(NGINX_EXPORTER_CONTAINER_NAME)"

logs:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(CONTAINER_NAME)"

monitoring-deploy:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_PLAYBOOK) --ask-vault-pass

prometheus-check:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_CHECK_PLAYBOOK) --tags targets

prometheus-config-check:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_CHECK_PLAYBOOK) --tags config

loki-check:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(LOKI_CHECK_PLAYBOOK)

prometheus-logs:
	$(ANSIBLE) -i $(INVENTORY) $(MONITORING_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(PROMETHEUS_CONTAINER_NAME)"

loki-logs:
	$(ANSIBLE) -i $(INVENTORY) $(MONITORING_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(LOKI_CONTAINER_NAME)"

promtail-logs:
	$(ANSIBLE) -i $(INVENTORY) $(APP_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(PROMTAIL_CONTAINER_NAME)"

grafana-update: monitoring-deploy

grafana-check:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(GRAFANA_CHECK_PLAYBOOK) --ask-vault-pass

grafana-alerting-check: grafana-check

grafana-alert-test:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_PLAYBOOK) --ask-vault-pass --extra-vars "grafana_test_alert_enabled=true"
	@echo "Test alert enabled. Wait up to 90 seconds, confirm the email, then run: make grafana-alert-test-reset"

grafana-alert-test-reset:
	$(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PROMETHEUS_PLAYBOOK) --ask-vault-pass --extra-vars "grafana_test_alert_enabled=false"
	@echo "Test alert returned to the normal state."

grafana-logs:
	$(ANSIBLE) -i $(INVENTORY) $(MONITORING_GROUP) --become -m ansible.builtin.command -a "docker logs --tail 100 $(GRAFANA_CONTAINER_NAME)"

terraform-fmt:
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) fmt -recursive

terraform-init:
	@test -n "$(TF_STATE_BUCKET)" || { echo "Set TF_STATE_BUCKET to the existing private state bucket name"; exit 1; }
	@test -n "$$AWS_ACCESS_KEY_ID" || { echo "Set AWS_ACCESS_KEY_ID for the Terraform state backend"; exit 1; }
	@test -n "$$AWS_SECRET_ACCESS_KEY" || { echo "Set AWS_SECRET_ACCESS_KEY for the Terraform state backend"; exit 1; }
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) init -reconfigure -backend-config="bucket=$(TF_STATE_BUCKET)"

terraform-validate:
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) validate

terraform-plan: terraform-validate
	@test -f "$(TERRAFORM_DIR)/$(TF_VAR_FILE)" || { echo "Copy terraform/terraform.tfvars.example to terraform/$(TF_VAR_FILE) and set your values"; exit 1; }
	@test -n "$$YC_TOKEN" || { echo "Set YC_TOKEN with: export YC_TOKEN=\"$$(yc iam create-token)\""; exit 1; }
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) plan -var-file="$(TF_VAR_FILE)" -out="$(TF_PLAN_FILE)"

terraform-apply:
	@test -f "$(TERRAFORM_DIR)/$(TF_PLAN_FILE)" || { echo "Run make terraform-plan first"; exit 1; }
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) apply "$(TF_PLAN_FILE)"

terraform-output:
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) output

terraform-kubeconfig:
	@cluster_id="$$( $(TERRAFORM) -chdir=$(TERRAFORM_DIR) output -raw kubernetes_cluster_id )"; \
		yc managed-kubernetes cluster get-credentials --id "$$cluster_id" --external --force

terraform-destroy:
	@test -f "$(TERRAFORM_DIR)/$(TF_VAR_FILE)" || { echo "Missing terraform/$(TF_VAR_FILE)"; exit 1; }
	@test -n "$$YC_TOKEN" || { echo "Set YC_TOKEN with: export YC_TOKEN=\"$$(yc iam create-token)\""; exit 1; }
	$(TERRAFORM) -chdir=$(TERRAFORM_DIR) destroy -var-file="$(TF_VAR_FILE)"

k8s-secret:
	$(KUBECTL) apply --filename $(K8S_DIR)/namespace.yaml
	KUBECTL="$(KUBECTL)" K8S_NAMESPACE="$(K8S_NAMESPACE)" \
		$(K8S_DIR)/sync-secret.sh

k8s-deploy: k8s-secret
	$(KUBECTL) apply --filename $(K8S_DIR)/configmap.yaml
	$(KUBECTL) apply --filename $(K8S_DIR)/migration-configmap.yaml
	$(KUBECTL) apply --filename $(K8S_DIR)/service.yaml
	$(KUBECTL) apply --filename $(K8S_DIR)/load-balancer.yaml
	$(KUBECTL) apply --filename $(K8S_DIR)/pod-disruption-budget.yaml
	@set -eu; \
		rendered_file="$$(mktemp "$${TMPDIR:-/tmp}/project-319-deployment.XXXXXX")"; \
		trap 'rm -f "$$rendered_file"' EXIT INT TERM; \
		$(KUBECTL) set image --filename $(K8S_DIR)/deployment.yaml \
			application="$(K8S_IMAGE)" --local --output yaml >"$$rendered_file"; \
		if [ ! -s "$$rendered_file" ]; then \
			cp $(K8S_DIR)/deployment.yaml "$$rendered_file"; \
		fi; \
		$(KUBECTL) apply --filename "$$rendered_file"
	$(KUBECTL) --namespace $(K8S_NAMESPACE) rollout status \
		deployment/$(K8S_DEPLOYMENT) --timeout=$(K8S_ROLLOUT_TIMEOUT)

k8s-status:
	$(KUBECTL) get nodes --output wide
	$(KUBECTL) --namespace $(K8S_NAMESPACE) get \
		deployment,pods,service,poddisruptionbudget --output wide
	$(KUBECTL) --namespace $(K8S_NAMESPACE) rollout status \
		deployment/$(K8S_DEPLOYMENT) --timeout=10s

k8s-check:
	@set -eu; \
		log_file="$${TMPDIR:-/tmp}/project-319-k8s-port-forward.log"; \
		$(KUBECTL) --namespace $(K8S_NAMESPACE) port-forward \
			service/$(K8S_SERVICE) 18080:80 19090:9090 >"$$log_file" 2>&1 & \
		forward_pid=$$!; \
		trap 'kill "$$forward_pid" 2>/dev/null || true; wait "$$forward_pid" 2>/dev/null || true' EXIT INT TERM; \
		ready=0; \
		for attempt in $$(seq 1 30); do \
			if curl --fail --silent --output /dev/null \
				http://127.0.0.1:19090/actuator/health/readiness; then \
				ready=1; \
				break; \
			fi; \
			sleep 1; \
		done; \
		if [ "$$ready" -ne 1 ]; then \
			cat "$$log_file"; \
			exit 1; \
		fi; \
		curl --fail --silent --show-error http://127.0.0.1:18080/api/bulletins >/dev/null; \
		curl --fail --silent --show-error http://127.0.0.1:19090/actuator/health/readiness; \
		echo; \
		echo "Application API and readiness endpoint are available."

k8s-public-url:
	@KUBECTL="$(KUBECTL)" \
		K8S_NAMESPACE="$(K8S_NAMESPACE)" \
		K8S_PUBLIC_SERVICE="$(K8S_PUBLIC_SERVICE)" \
		K8S_PUBLIC_CHECK_REQUESTS=0 \
		$(K8S_DIR)/public-check.sh

k8s-public-check:
	@KUBECTL="$(KUBECTL)" \
		K8S_NAMESPACE="$(K8S_NAMESPACE)" \
		K8S_PUBLIC_SERVICE="$(K8S_PUBLIC_SERVICE)" \
		K8S_PUBLIC_CHECK_REQUESTS="$(K8S_PUBLIC_CHECK_REQUESTS)" \
		$(K8S_DIR)/public-check.sh

k8s-rollout-check:
	@KUBECTL="$(KUBECTL)" \
		K8S_NAMESPACE="$(K8S_NAMESPACE)" \
		K8S_DEPLOYMENT="$(K8S_DEPLOYMENT)" \
		K8S_SERVICE="$(K8S_SERVICE)" \
		K8S_PUBLIC_SERVICE="$(K8S_PUBLIC_SERVICE)" \
		K8S_NEW_IMAGE="$(K8S_NEW_IMAGE)" \
		K8S_DISTRIBUTION_REQUESTS="$(K8S_DISTRIBUTION_REQUESTS)" \
		K8S_ROLLOUT_TIMEOUT="$(K8S_ROLLOUT_TIMEOUT)" \
		$(K8S_DIR)/rolling-update-check.sh

k8s-port-forward:
	$(KUBECTL) --namespace $(K8S_NAMESPACE) port-forward \
		service/$(K8S_SERVICE) 8080:80 9090:9090

k8s-logs:
	$(KUBECTL) --namespace $(K8S_NAMESPACE) logs \
		deployment/$(K8S_DEPLOYMENT) --all-pods=true --tail=100
