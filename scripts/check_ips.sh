#!/bin/bash

# Check available IPs in a configurable network range
# Usage: ./scripts/check_ips.sh [network] [start] [end]
# Example: ./scripts/check_ips.sh 10.196.244 10 50
# Example: ./scripts/check_ips.sh 192.168.1 100 150

NETWORK=${1:-"10.196.244"}
START=${2:-10}
END=${3:-50}

echo "========================================"
echo "IP Availability Check: $NETWORK.$START - $NETWORK.$END"
echo "========================================"
echo ""

# Check IPs allocated in Terraform state
echo "🔹 IPs in Terraform State:"
if [ -f terraform/terraform.tfstate ]; then
    grep -o '"default_ip_address": "[^"]*"' terraform/terraform.tfstate | grep "10.196.244" | sed 's/"default_ip_address": "\(.*\)"/  - \1/' | sort -u
    echo ""
else
    echo "  (No terraform.tfstate found)"
    echo ""
fi

# Check IPs in Ansible inventory
echo "🔹 IPs in Ansible Inventory:"
if [ -f ansible/inventory/hosts.yml ]; then
    grep -o 'ansible_host: [0-9.]*' ansible/inventory/hosts.yml | grep "$NETWORK" | awk '{print "  - " $2}' | sort -u
    echo ""
else
    echo "  (No ansible inventory found)"
    echo ""
fi

# Ping scan for active IPs
echo "🔹 Live Scan Results (responding to ping):"
echo "  RESPONDING (likely in use):"
for i in $(seq $START $END); do
    if ping -c 1 -W 1 $NETWORK.$i > /dev/null 2>&1; then
        echo "    ✓ $NETWORK.$i"
    fi
done

echo ""
echo "  NOT RESPONDING (possibly available):"
for i in $(seq $START $END); do
    if ! ping -c 1 -W 1 $NETWORK.$i > /dev/null 2>&1; then
        echo "    ○ $NETWORK.$i"
    fi
done

echo ""
echo "========================================"
echo "Note: IPs not responding may be:"
echo "  - Available for use"
echo "  - Not yet booted"
echo "  - Behind a firewall blocking ICMP"
echo "========================================"
