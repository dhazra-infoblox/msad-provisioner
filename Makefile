CONFIG  ?= config/environment.yml
TF_DIR  ?= terraform
TF_VARS ?= -var="config_file=../$(CONFIG)" -var-file="secret.tfvars"

.PHONY: help login init validate plan apply destroy redeploy output status progress logs creds

help:
	@echo "Targets:"
	@echo "  Passwords: edit terraform/secret.tfvars (gitignored)"
	@echo "  make login           - AWS SSO login"
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
	@echo "  make creds           - show all VM credentials"
	@echo "  make creds HOST=name - show credentials for one VM"

AWS_PROFILE ?= $(shell python3 -c "import yaml; print(yaml.safe_load(open('$(CONFIG)'))['aws']['profile'])" 2>/dev/null || echo "dibya-aws")

login:
	aws sso login --profile $(AWS_PROFILE)

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

HOST ?=
creds:
	@CONFIG_FILE=$(CONFIG) ./scripts/creds.sh $(HOST)
