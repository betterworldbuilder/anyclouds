#!/usr/bin/env bash
# get_console.sh
# Script to get the console logs of a FLEX OpenStack instance by its IP address

if [ -z "$1" ]; then
    echo "Usage: ./get_console.sh <ip_address>"
    echo "Example: ./get_console.sh 174.143.59.140"
    exit 1
fi

IP="$1"

# Automatically export OpenRC for FLEX if not set
if [ -z "$OS_AUTH_URL" ]; then
    export OS_AUTH_URL=https://keystone.api.dfw3.rackspacecloud.com/v3/
    export OS_IDENTITY_API_VERSION=3
    export OS_INTERFACE=public
    export OS_REGION_NAME=DFW3
    export OS_AUTH_TYPE=password
    export OS_USERNAME=dzng.8294
    export OS_PASSWORD=0b6f44aad11f4c6fbaeaa159151dd316
    export OS_API_KEY=0b6f44aad11f4c6fbaeaa159151dd316
    export OS_USER_DOMAIN_NAME=rackspace_cloud_domain
    export OS_PROJECT_DOMAIN_NAME=rackspace_cloud_domain
    export OS_PROJECT_ID=49a2c18a567c402ef560bb0f11821b61
    export OS_PROJECT_NAME=49a2c18a567c402ef560bb0f11821b61
fi

OS_CMD="openstack"
if ! command -v $OS_CMD &> /dev/null; then
    if [ -f "$HOME/.local/bin/openstack" ]; then
        OS_CMD="$HOME/.local/bin/openstack"
    elif [ -f "$HOME/OSPC2FLEX/venv/bin/openstack" ]; then
        OS_CMD="$HOME/OSPC2FLEX/venv/bin/openstack"
    else
        echo "Error: openstack CLI not found in PATH."
        exit 1
    fi
fi

echo "Searching for instance with IP: $IP..."

# Get server ID by querying all projects for the specific IP
SERVER_ID=$($OS_CMD server list --ip "$IP" -f value -c ID 2>/dev/null | head -n 1)

if [ -z "$SERVER_ID" ]; then
    echo "Error: Could not find any OpenStack instance associated with IP $IP in region $OS_REGION_NAME."
    echo "Please ensure the instance exists and the IP is correct."
    exit 1
fi

echo "Found Server ID: $SERVER_ID"
echo "Fetching full console logs (this may take a moment)..."
echo "========================================================"
$OS_CMD console log show "$SERVER_ID"
echo "========================================================"
