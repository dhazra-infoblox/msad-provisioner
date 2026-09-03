# AWS MSAD Multi-Server Implementation Plan

## Scope (Current Phase)
Build a simple multi-server baseline on AWS using Terraform + SSM:
- 3 Windows Server 2025 VMs
- 2 member servers (role `srv`): `srv01`, `srv02` — each running AD tools, DNS and DHCP
- 1 agent client (role `clt`): `clt01`
- All hosts in the same AD forest/domain
- Full credential and remoting setup for object collection from both server hosts

Nestle large-scale sizing/distribution requirements are deferred and kept as backlog context.

## Architecture
- Infrastructure provisioning: Terraform
- Host configuration and orchestration: AWS SSM documents/associations
- Input model: YAML (`config/environment.yml`)
- Operator workflow: Makefile targets (`init`, `plan`, `apply`, `status`, `progress`, etc.)

## Role Model
- `dc`: must be promoted to DC
- `srv`: domain-joined member server (DNS + DHCP + AD tools), no DC promotion
- `clt`: domain-joined management/collector host, no DC promotion

The longer names used earlier — `domain_controller`, `dhcp_server`, `agent_client` — are still
accepted as aliases.

## Workflow
1. Parse YAML config and validate role/host/domain rules.
2. Allocate free private IPs from target subnet.
3. Provision EC2 instances with SSM instance profile.
4. Configure static networking in Windows (disable DHCP).
5. Install required Windows roles/tools by role.
6. Bootstrap AD forest on one designated bootstrap host.
7. Join remaining hosts to same domain.
8. Create service user and apply groups/permissions:
   - Domain Users
   - Remote Management Users
   - DNSAdmins
   - DHCP Administrator(s)
9. Configure remoting/security prerequisites:
   - WMI permissions for DNS and DHCP namespaces
   - CredSSP server/client
   - TrustedHosts
   - WinRM/firewall rules
10. Configure the `clt01` target list for `srv01` and `srv02`.
11. Expose status/progress through SSM association outputs.

## Deliverables in Repo
- Terraform AWS baseline replacing vSphere code
- YAML config template for 3-host setup
- SSM documents/associations for staged setup
- Outputs for host inventory, role mapping, phase IDs
- `Makefile` commands for day-2 operations
- `scripts/progress.sh` for progress polling

## Verification Checklist
1. 3 hosts provisioned with expected roles and static private IPs.
2. One forest/domain created; all 3 hosts domain-joined.
3. DNS and DHCP roles installed on `srv01` and `srv02`.
4. RSAT/tools installed on `clt01`.
5. Service user created with required group memberships.
6. Remoting prerequisites validated from agent to server hosts.
7. Agent can access DNS and DHCP object paths (zones, subnets, reservations, leases).
8. Progress/status commands show per-phase state and completion.
9. Re-run is idempotent.

## Backlog (Deferred)
- Promotion of additional `dc` hosts (`Install-ADDSDomainController`) for multi-DC domains
- Nestle-scale regional distribution and 10-vs-20 servers/agent planning mode
- Advanced DNS zone/record automation
- DHCP scope/options/reservations policy automation
- Spot strategy for non-stateful roles
