CONFIG  ?= config/environment.yml
TF_DIR  ?= terraform
TF_VARS ?= -var="config_file=../$(CONFIG)" -var-file="secret.tfvars"

.PHONY: help login vault-start vault-stop vault-status vault-setup init validate plan apply destroy redeploy output status progress logs creds

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

AWS_PROFILE ?= $(shell python3 -c "import yaml; print(yaml.safe_load(open('$(CONFIG)'))['aws']['profile'])" 2>/dev/null || echo "dibya-aws")

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
