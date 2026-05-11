# Plan: Add Dev Workstation VM Role to msad-provisioner

## TL;DR
Extend msad-provisioner Terraform to support standalone Windows dev workstations (non-domain-joined) with 16GB RAM, 300GB disk, and preinstalled dev tools. Add a new "dev_workstation" role that provisions VMs via SSM with automated tool installation. Template: Based on existing dev machine setup (Visual Studio 2022 Community with WiX extensions, WiX v3 command-line tools, Git, GitHub CLI, .NET 8 SDK, Go).

## Steps

### Phase 1: Extend Terraform Configuration

1. **Add dev_workstation role variable to terraform/variables.tf**
   - Define allowed_roles to include "dev_workstation"
   - Document new role in validation

2. **Update terraform/main.tf to support dev_workstation**
   - Modify `aws_instance.nodes` to use t2.xlarge (16GB RAM)
   - Update `locals.disk_sizes` to allow 300GB overrides per host
   - Add conditional logic: skip domain/DHCP networking config for "dev_workstation" role
   - Dev workstations only need:
     - Rename computer phase
     - Basic Windows networking (DHCP or static IP)
     - Install dev tools phase (new)
   - Skip: install_windows_features (DHCP/DNS/RSAT), bootstrap_domain, join_domain, credential_setup, agent_setup

3. **Create new SSM documents for dev workstation provisioning**
   - `install_dev_tools` — PowerShell script that:
     - Installs Chocolatey (package manager)
     - Installs Visual Studio 2022 Community (with Workloads: Desktop, ASP.NET, .NET Core, Office)
       - Includes WiX extensions: WiX v3 Schemas, WiX v3 - VS 2022 Extension (via VS installer)
       - Installs WiX Toolset v3.14 command-line tools (candle, light, heat)
       - Note: WiX v3 installs to C:\Program Files (x86)\WiX Toolset v3.14\bin — must be explicitly added to machine PATH
       - Note: `wix` command does NOT exist; that is WiX v4+ CLI. Use `candle`, `light`, `heat` for v3
     - Installs Git for Windows v2.52+ (includes Git Bash)
     - Installs GitHub CLI
     - Installs .NET 8 SDK (LTS, primary dev runtime)
     - Installs Go Programming Language go1.26.3 (pin this version for reproducibility)
       - Note: Go installs to C:\Program Files\Go but does NOT self-register in machine PATH — must be added explicitly post-install
     - After all installs, explicitly append Go and WiX bin dirs to machine-level PATH and validate with `where.exe`
     - Installs Visual C++ redistributables (2022)
     - Microsoft Edge browser
     - Logs output for verification
   - Consider: Chocolatey silent installs or direct MSI/EXE downloads for reproducibility
   - Reference: existing dev machine's confirmed tool list for exact versions

4. **Add dev_workstation phase orchestration in Terraform**
   - Use `time_sleep` to sequence phases: rename → configure_networking → install_dev_tools
   - Dev VMs should complete in ~45 min (VS install is lengthy)

### Phase 2: Update YAML Configuration Structure

5. **Extend config/environment.yml.example**
   - Add documentation for dev_workstation role
   - Show example dev VM entry:
     ```yaml
     hosts:
       - name: devbox-001
         role: dev_workstation
         bootstrap: false
         instance_type: t2.xlarge
         disk_gb: 300
     ```

6. **No changes to aws/domain/network/credentials sections**
   - Dev VMs use same AWS, security groups, subnet as infrastructure VMs
   - Domain config is ignored for dev_workstation role
   - Static IPs assigned from same pool as other hosts

### Phase 3: Testing & Validation

7. **Create minimal test config** (non-committed, for manual testing)
   - Add one dev_workstation entry to environment.yml
   - `terraform plan` to validate syntax
   - `terraform apply` to provision

8. **Verify on provisioned VM**
   - RDP to dev workstation
   - Confirm installed: Visual Studio, WiX, Git Bash, .NET 8 SDK, Go, GitHub CLI
   - Confirm network access (if needed)
   - Check C:\ drive size (should be ~300GB)
   - Check RAM (16GB available)

9. **Do not add dev-specific Makefile targets**
   - Keep provisioning via Terraform commands and existing workflows
   - Document the Terraform apply/destroy flow in README.md instead

### Phase 4: Documentation & Handoff

10. **Update README.md**
    - Document dev_workstation role
    - Add example YAML config
    - List preinstalled tools
    - Add RDP/connection instructions
    - Note: dev VMs are standalone, not domain-joined

11. **Update TROUBLESHOOTING.md**
    - Add section: "Dev Workstation Provisioning Issues"
    - Document common Visual Studio/WiX installation failures
    - Document log locations (CloudWatch or S3, via ssm_logs_s3_path)

## Relevant Files to Modify
- terraform/main.tf — Extend instance provisioning, add dev_workstation conditional logic, add install_dev_tools phase
- terraform/variables.tf — Add dev_workstation to allowed_roles validation
- terraform/outputs.tf — Add optional output for dev workstation IPs (e.g., `dev_workstations` output)
- config/environment.yml.example — Document dev_workstation role
- README.md — Add dev workstation setup instructions
- TROUBLESHOOTING.md — Add dev VM provisioning troubleshooting

## Verification Checklist
1. **Terraform validation**: `terraform plan` shows no errors; dev_workstation host creates one t2.xlarge instance with 300GB disk
2. **Provisioning success**: SSM phases complete (rename → networking → dev_tools install) within ~45 min, no failures
3. **Manual VM check**: RDP to dev workstation, verify:
   - Computer name matches YAML entry
   - Visual Studio 2022 Community installed and runs
   - WiX extensions installed in VS (Extensions → Manage Extensions → Installed tab shows "WiX v3 - Visual Studio 2022 Extension")
   - WiX v3 CLI available: `where.exe candle`, `where.exe light`, `where.exe heat` all resolve to C:\Program Files (x86)\WiX Toolset v3.14\bin
   - Git Bash available: `git --version` works
   - GitHub CLI available: `gh --version` works
   - .NET 8 SDK installed: `dotnet --version` returns 8.x.x
   - Go installed and on PATH: `go version` returns go1.26.3 and `where.exe go` resolves to C:\Program Files\Go\bin\go.exe
   - C:\ drive shows ~300GB total size
   - 16GB RAM available

## Key Decisions
- **No domain join**: Dev VMs intentionally standalone to avoid dependency on DC/DHCP infrastructure
- **Reuse existing Terraform pattern**: Extend main.tf with conditional logic rather than separate module (simpler for single project)
- **SSM-based provisioning**: Consistent with existing DC/DHCP/Agent roles; logs to CloudWatch/S3
- **Instance type**: t2.xlarge provides 16GB RAM cost-effectively; if insufficient, can switch to m5.large or m5.xlarge
- **Chocolatey for tools**: Simplifies large tool installations (Visual Studio, WiX); fallback to direct downloads if needed
- **Deterministic PATH setup**: Provisioning must append WiX and Go locations to machine PATH and verify with `where.exe`

## Further Considerations
1. **Visual Studio installation time**: VS 2022 Community + WiX + .NET SDKs can take 30-45 minutes total. Consider splitting into phases if needed for faster initial provisioning.
2. **Storage sizing**: Verify 300GB is sufficient with all tools (rough estimate: VS ~15GB, WiX ~5GB, .NET SDKs ~10GB, Go ~1GB, leaving ~260GB for dev work and code repos)
3. **Windows licensing**: Confirm AWS account has Windows licensing for dev workstations (typically included in standard EC2 Windows AMIs)
4. **Scaling for multiple devs**: Once working, devs can fork/clone config and add their own dev_workstation entry to create N VMs
