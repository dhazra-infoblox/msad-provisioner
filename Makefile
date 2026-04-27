CONFIG  ?= config/environment.yml
TF_DIR  ?= terraform
TF_VARS ?= -var="config_file=../$(CONFIG)" -var-file="secret.tfvars"

.PHONY: help login vault-start vault-stop vault-status vault-setup init validate plan apply destroy redeploy output status progress logs creds check-prereqs fix-prereqs

help:
	@echo "Targets:"
	@echo "  Passwords: edit terraform/secret.tfvars (gitignored)"
	@echo "  Vault env: export VAULT_ADDR=... VAULT_TOKEN=..."
	@echo "  make login           - AWS SSO login"
	@echo "  make vault-start     - start Vault dev server (background)"
	@echo "  make vault-stop      - stop Vault dev server"
	@echo "  make vault-status    - check Vault server status"
	@echo "  make vault-setup     - enable KV v2 engine at secret/"
	@echo "  make init            - terraform init"
	@echo "  make validate        - terraform validate"
	@echo "  make plan            - terraform plan"
	@echo "  make apply           - terraform apply"
	@echo "  make destroy         - terraform destroy"
	@echo "  make redeploy        - destroy and apply (clean deploy)"
	@echo "  make output          - terraform output"
	@echo "  make status          - quick host inventory status"
	@echo "  make progress        - phase progress from SSM associations"
	@echo "  make logs            - list SSM log phases in S3"
	@echo "  make logs PHASE=x    - list hosts with logs for a phase"
	@echo "  make logs PHASE=x HOST=y         - show latest run"
	@echo "  make logs PHASE=x HOST=y RUN=all - list all runs"
	@echo "  make logs PHASE=x HOST=y RUN=N   - show run N"
	@echo "  make creds           - list all VM credential Vault paths"
	@echo "  make creds HOST=name - show credentials for a specific VM"
	@echo "  make check-prereqs HOST=name   - check Infoblox DHCP prerequisites on a host"
	@echo "  make fix-prereqs HOST=name     - check and fix prerequisites on a host"

# Helper: extract a field from a YAML section using awk (no pyyaml dependency).
_yaml_field = $(shell awk -v sec="$(1)" -v key="$(2)" '$$0 ~ "^"sec":" { in_sec=1; next } in_sec && /^[^[:space:]]/ { in_sec=0 } in_sec && $$1 == key":" { $$1=""; sub(/^[[:space:]]+/, ""); gsub(/["'"'"']/, ""); print; exit }' $(CONFIG))

AWS_PROFILE ?= $(or $(call _yaml_field,aws,profile),dibya-aws)

login:
	aws sso login --profile $(AWS_PROFILE)

TOKEN ?= dev-root
vault-start:
	@echo "Starting Vault dev server…"
	@vault server -dev -dev-root-token-id=$(TOKEN) -dev-listen-address=127.0.0.1:8200 > /tmp/vault-dev.log 2>&1 &
	@sleep 1
	@echo "export VAULT_ADDR=http://127.0.0.1:8200"
	@echo "export VAULT_TOKEN=$(TOKEN)"
	@echo "Logs: /tmp/vault-dev.log"

vault-stop:
	@pkill -f 'vault server -dev' 2>/dev/null && echo "Vault dev server stopped" || echo "Vault dev server not running"

VAULT_ADDR ?= http://127.0.0.1:8200

vault-status:
	VAULT_ADDR=$(VAULT_ADDR) vault status

vault-setup:
	@echo "Enabling KV v2 at secret/ …"
	@VAULT_ADDR=$(VAULT_ADDR) vault secrets enable -path=secret -version=2 kv 2>/dev/null || echo "KV engine already enabled at secret/"
	@echo "Vault ready for make apply"

init:
	terraform -chdir=$(TF_DIR) init

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) plan $(TF_VARS)

apply:
	terraform -chdir=$(TF_DIR) apply $(TF_VARS) --auto-approve

destroy:
	terraform -chdir=$(TF_DIR) destroy $(TF_VARS) --auto-approve

redeploy: destroy apply

output:
	terraform -chdir=$(TF_DIR) output

status:
	terraform -chdir=$(TF_DIR) output host_inventory

progress:
	./scripts/progress.sh

# Show SSM command output logs stored in S3.
# Usage: make logs                       → list phases with logs
#        make logs PHASE=join-domain      → list hosts for that phase
#        make logs PHASE=join-domain HOST=dhcp02 → show latest stdout/stderr
#        make logs PHASE=join-domain HOST=dhcp02 RUN=all → list all runs
#        make logs PHASE=join-domain HOST=dhcp02 RUN=1   → show specific run
PHASE ?=
RUN   ?=
logs:
	@./scripts/ssm_logs.sh $(PHASE) $(HOST) $(RUN)

# Read VM credentials from Vault.
# Usage: make creds            → list all stored paths
#        make creds HOST=dhcp01 → show full credentials for that VM
HOST ?=
creds:
	@if [ -z "$(HOST)" ]; then \
		echo "=== Stored credential paths ==="; \
		terraform -chdir=$(TF_DIR) output -json rdp_credentials_vault_paths 2>/dev/null | \
			python3 -c "import sys,json; [print(f'{h}: {p}') for h,p in sorted(json.load(sys.stdin).items())]" || \
			echo "Run 'make apply' first (and set key_pair_pem_path in secret.tfvars)."; \
	else \
		echo "=== Credentials for $(HOST) ==="; \
		vault kv get -format=json secret/msad/rdp/$(HOST) 2>/dev/null | \
			python3 -c "import sys,json; d=json.load(sys.stdin)['data']['data']; [print(f'{k}: {v}') for k,v in d.items()]" || \
			echo "Not found. Ensure apply ran with key_pair_pem_path set and HOST=$(HOST) exists."; \
	fi

AWS_REGION      ?= $(call _yaml_field,aws,region)

_require_host:
	@if [ -z "$(HOST)" ]; then echo "ERROR: HOST is required. Usage: make $@ HOST=client01"; exit 1; fi

_resolve_instance_id:
	$(eval INSTANCE_ID := $(shell terraform -chdir=$(TF_DIR) output -json host_inventory 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('$(HOST)',{}).get('instance_id',''))" 2>/dev/null))
	@if [ -z "$(INSTANCE_ID)" ]; then echo "ERROR: Could not resolve instance ID for HOST=$(HOST). Run 'make apply' first."; exit 1; fi


# ---------------------------------------------------------------------------
# Prerequisite checker: run check-prerequisites.ps1 on a host via SSM.
# Usage: make check-prereqs HOST=dhcp01
#        make fix-prereqs   HOST=client01
# Auto-detects role from Terraform host_inventory.
# ---------------------------------------------------------------------------

DOMAIN_FQDN ?= $(call _yaml_field,domain,fqdn)
SVC_USER    ?= $(call _yaml_field,credentials,service_user)

_resolve_role = $(eval HOST_ROLE := $(shell terraform -chdir=$(TF_DIR) output -json host_inventory 2>/dev/null | \
	python3 -c "import sys,json; print(json.load(sys.stdin).get('$(HOST)',{}).get('role',''))" 2>/dev/null))

_resolve_targets = $(eval TARGET_IPS := $(shell terraform -chdir=$(TF_DIR) output -json host_inventory 2>/dev/null | \
	python3 -c "import sys,json; inv=json.load(sys.stdin); print(','.join(v['private_ip'] for k,v in inv.items() if v.get('role') in ('dhcp_server','domain_controller') and k != '$(HOST)'))" 2>/dev/null))

_map_role = $(if $(filter agent_client,$(HOST_ROLE)),AgentClient,$(if $(filter dhcp_server,$(HOST_ROLE)),DhcpServer,$(if $(filter domain_controller,$(HOST_ROLE)),DomainController,)))

check-prereqs: _require_host _resolve_instance_id
	$(_resolve_role)
	$(_resolve_targets)
	$(eval PS_ROLE := $(call _map_role))
	@if [ -z "$(PS_ROLE)" ]; then echo "ERROR: Could not determine role for HOST=$(HOST) (role='$(HOST_ROLE)')"; exit 1; fi
	@echo "=== Checking prerequisites on $(HOST) ($(INSTANCE_ID)) role=$(PS_ROLE) ==="
	@scripts/run_prereqs_via_ssm.sh \
		--profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" \
		--instance-id "$(INSTANCE_ID)" \
		--role "$(PS_ROLE)" \
		--script scripts/check-prerequisites.ps1 \
		$(if $(filter AgentClient,$(PS_ROLE)),--targets "$(TARGET_IPS)" --domain "$(DOMAIN_FQDN)",) \
		$(if $(filter DomainController DhcpServer,$(PS_ROLE)),--service-user "$(SVC_USER)",)

fix-prereqs: _require_host _resolve_instance_id
	$(_resolve_role)
	$(_resolve_targets)
	$(eval PS_ROLE := $(call _map_role))
	@if [ -z "$(PS_ROLE)" ]; then echo "ERROR: Could not determine role for HOST=$(HOST) (role='$(HOST_ROLE)')"; exit 1; fi
	@echo "=== Checking & FIXING prerequisites on $(HOST) ($(INSTANCE_ID)) role=$(PS_ROLE) ==="
	@scripts/run_prereqs_via_ssm.sh \
		--profile "$(AWS_PROFILE)" --region "$(AWS_REGION)" \
		--instance-id "$(INSTANCE_ID)" \
		--role "$(PS_ROLE)" --fix \
		--script scripts/check-prerequisites.ps1 \
		$(if $(filter AgentClient,$(PS_ROLE)),--targets "$(TARGET_IPS)" --domain "$(DOMAIN_FQDN)",) \
		$(if $(filter DomainController DhcpServer,$(PS_ROLE)),--service-user "$(SVC_USER)",)
