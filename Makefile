SETUP_TARGETS := create-setup validate plan apply destroy redeploy output status progress creds
POSITIONAL_SETUP := $(word 2,$(MAKECMDGOALS))

ifeq ($(origin SETUP), undefined)
ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(SETUP_TARGETS)),)
ifneq ($(POSITIONAL_SETUP),)
SETUP := $(POSITIONAL_SETUP)
else
SETUP := default
endif
else
SETUP := default
endif
else
SETUP := $(SETUP)
endif

CONFIG  ?= $(if $(filter default,$(SETUP)),config/environment.yml,config/$(SETUP).yml)
TF_DIR  ?= terraform
SECRET_FILE ?= $(if $(filter default,$(SETUP)),secret.tfvars,secret.$(SETUP).tfvars)
TF_VARS ?= -var="config_file=../$(CONFIG)" -var-file="$(SECRET_FILE)"

ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(SETUP_TARGETS)),)
ifneq ($(POSITIONAL_SETUP),)
.PHONY: $(POSITIONAL_SETUP)
$(POSITIONAL_SETUP):
	@:
endif
endif

.PHONY: help login init ensure-workspace create-setup validate plan apply destroy redeploy output status progress logs creds

help:
	@echo "Targets:"
	@echo "  Passwords: edit terraform/secret.tfvars (or terraform/secret.<setup>.tfvars)"
	@echo "  SETUP=<name> or 2nd arg - select a named setup (default: 'default')"
	@echo "    config:  config/environment.yml for default, config/<setup>.yml otherwise"
	@echo "    secrets: terraform/secret.tfvars for default, terraform/secret.<setup>.tfvars otherwise"
	@echo "    state:   terraform workspace '<setup>' (auto-created on first use)"
	@echo "  make login           - AWS SSO login"
	@echo "  make create-setup SETUP=name"
	@echo "  make create-setup name"
	@echo "                       - create config/<setup>.yml and terraform/secret.<setup>.tfvars"
	@echo "  make init            - terraform init"
	@echo "  make validate        - terraform validate"
	@echo "  make plan [name]     - terraform plan"
	@echo "  make apply [name]    - terraform apply"
	@echo "  make destroy [name]  - terraform destroy"
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

create-setup:
	@test "$(SETUP)" != "default" || (echo "SETUP must be set to a non-default setup name" >&2; exit 1)
	@SETUP="$(SETUP)" DOMAIN="$(DOMAIN)" IP_OFFSET="$(IP_OFFSET)" \
		NETBIOS="$(NETBIOS)" NAME_PREFIX="$(NAME_PREFIX)" \
		bash ./scripts/create_setup.sh

ensure-workspace:
	@terraform -chdir=$(TF_DIR) workspace select $(SETUP) 2>/dev/null \
	  || terraform -chdir=$(TF_DIR) workspace new $(SETUP)

validate: ensure-workspace
	terraform -chdir=$(TF_DIR) validate

plan: ensure-workspace
	terraform -chdir=$(TF_DIR) plan $(TF_VARS)

apply: ensure-workspace
	terraform -chdir=$(TF_DIR) apply $(TF_VARS) --auto-approve

destroy: ensure-workspace
	terraform -chdir=$(TF_DIR) destroy $(TF_VARS) --auto-approve

redeploy: destroy apply

output: ensure-workspace
	terraform -chdir=$(TF_DIR) output

status: ensure-workspace
	terraform -chdir=$(TF_DIR) output host_inventory

progress: ensure-workspace
	@CONFIG_FILE=$(CONFIG) TF_WORKSPACE=$(SETUP) ./scripts/progress.sh

# Show SSM command output logs stored in S3.
# Usage: make logs                       → list phases with logs
#        make logs PHASE=join-domain      → list hosts for that phase
#        make logs PHASE=join-domain HOST=dhcp02 → show latest stdout/stderr
#        make logs PHASE=join-domain HOST=dhcp02 RUN=all → list all runs
#        make logs PHASE=join-domain HOST=dhcp02 RUN=1   → show specific run
PHASE ?=
RUN   ?=
logs:
	@CONFIG_FILE=$(CONFIG) ./scripts/ssm_logs.sh $(PHASE) $(HOST) $(RUN)

HOST ?=
creds: ensure-workspace
	@CONFIG_FILE=$(CONFIG) TF_WORKSPACE=$(SETUP) SECRET_TFVARS=$(TF_DIR)/$(SECRET_FILE) ./scripts/creds.sh $(HOST)
