#!/usr/bin/env python3
"""Stamp current Terraform-assigned IPs into the config YAML as explicit 'ip:' fields.

Run this once after initial deployment (and after adding new hosts) to pin each
host's IP so that adding or removing other hosts never shifts IPs for existing
machines.

Usage: python3 scripts/lock_ips.py <config.yml> <tf_dir>
"""

import json
import re
import subprocess
import sys


def get_ip_map(tf_dir):
    """Map host name -> private IP, read from the state file.

    Deliberately not the host_inventory output: Terraform only recomputes
    outputs at the end of a *successful* apply, so after a partial failure the
    output still describes the previous run. Pinning from it would silently skip
    the hosts that were just created, leaving them to keep drawing from the
    auto-assign pool — which is the exact shuffling this script exists to stop.
    The state is written as each resource completes, so it sees every instance.
    """
    result = subprocess.run(
        ["terraform", f"-chdir={tf_dir}", "show", "-json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"terraform show failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    doc = json.loads(result.stdout)
    resources = doc.get("values", {}).get("root_module", {}).get("resources", [])

    ip_map = {}
    for res in resources:
        if res.get("type") != "aws_instance" or res.get("name") != "nodes":
            continue
        name, private_ip = res.get("index"), res.get("values", {}).get("private_ip")
        if name and private_ip:
            ip_map[str(name)] = private_ip
    return ip_map


def patch_yaml(config_file, ip_map):
    with open(config_file) as f:
        lines = f.readlines()

    result = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # Match start of a host entry: "  - name: hostname"
        m = re.match(r"^(\s+)-\s+name:\s+(\S+)", line)
        if m:
            indent = m.group(1)
            host_name = m.group(2)
            ip = ip_map.get(host_name)

            if not ip:
                result.append(line)
                i += 1
                continue

            # Collect all lines of this host block (until next sibling entry)
            i += 1
            block_lines = []
            while i < len(lines):
                bl = lines[i]
                if re.match(r"^" + re.escape(indent) + r"-", bl):
                    break
                block_lines.append(bl)
                i += 1

            ip_field_re = re.compile(r"^(\s+)ip:\s")

            if any(ip_field_re.match(bl) for bl in block_lines):
                # Update existing ip: line in place
                result.append(line)
                for bl in block_lines:
                    ip_m = ip_field_re.match(bl)
                    if ip_m:
                        result.append(f"{ip_m.group(1)}ip: {ip}\n")
                    else:
                        result.append(bl)
            else:
                # Insert ip: immediately after the name: line, using same indent
                # as other fields in the block
                field_indent = None
                for bl in block_lines:
                    fm = re.match(r"^(\s+)\w", bl)
                    if fm:
                        field_indent = fm.group(1)
                        break
                if not field_indent:
                    field_indent = " " * (len(indent) + 4)

                result.append(line)
                result.append(f"{field_indent}ip: {ip}\n")
                result.extend(block_lines)
            continue

        result.append(line)
        i += 1

    with open(config_file, "w") as f:
        f.writelines(result)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <config.yml> <tf_dir>", file=sys.stderr)
        sys.exit(1)

    config_file, tf_dir = sys.argv[1], sys.argv[2]
    ip_map = get_ip_map(tf_dir)

    if not ip_map:
        print("No hosts found in terraform output — is the workspace applied?", file=sys.stderr)
        sys.exit(1)

    patch_yaml(config_file, ip_map)

    print(f"Pinned IPs for {len(ip_map)} hosts in {config_file}:")
    for name, ip in sorted(ip_map.items()):
        print(f"  {name}: {ip}")


if __name__ == "__main__":
    main()
