#!/usr/bin/env bash

# Interactive Ping + SSH Tester
# Stops when IP is blank
# Handles stale SSH known_hosts entries
# Prints final summary table

RESULTS=()

SSH_TIMEOUT=7
PING_COUNT=2
PING_TIMEOUT=2

print_line() {
    echo "--------------------------------------"
}

test_ping() {
    local ip="$1"

    echo "Pinging $ip..."

    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
        echo "✅ Ping OK: $ip"
        return 0
    else
        echo "❌ Ping FAILED: $ip"
        return 1
    fi
}

test_ssh() {
    local ip="$1"
    local user="$2"
    local output
    local rc

    echo "Testing SSH to ${user}@${ip}..."

    output=$(ssh \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
        "${user}@${ip}" "hostname" 2>&1)

    rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "✅ SSH OK on $output"
        return 0
    fi

    echo "$output"

    if echo "$output" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
        echo "⚠️ Stale SSH host key detected for $ip"
        echo "Fixing known_hosts entry..."

        ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1

        echo "Retrying SSH to ${user}@${ip}..."

        output=$(ssh \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
            "${user}@${ip}" "hostname" 2>&1)

        rc=$?

        if [[ $rc -eq 0 ]]; then
            echo "✅ SSH OK after known_hosts fix on $output"
            return 0
        else
            echo "$output"
            return 1
        fi
    fi

    return 1
}

while true; do
    echo
    read -rp "Enter IP address (blank to quit): " IP

    if [[ -z "$IP" ]]; then
        break
    fi

    read -rp "Enter SSH username for $IP: " USERNAME

    if [[ -z "$USERNAME" ]]; then
        echo "❌ Username cannot be blank"
        RESULTS+=("$IP|N/A|SKIPPED|FAILED|Blank username")
        print_line
        continue
    fi

    PING_STATUS="FAILED"
    SSH_STATUS="FAILED"
    NOTE=""

    if test_ping "$IP"; then
        PING_STATUS="OK"

        if test_ssh "$IP" "$USERNAME"; then
            SSH_STATUS="OK"
            NOTE="SSH successful"
            echo "✅ SSH test successful: ${USERNAME}@${IP}"
        else
            SSH_STATUS="FAILED"
            NOTE="SSH failed"
            echo "❌ SSH test failed: ${USERNAME}@${IP}"
        fi
    else
        NOTE="Ping failed, SSH skipped"
        echo "❌ SSH skipped because ping failed"
    fi

    RESULTS+=("$IP|$USERNAME|$PING_STATUS|$SSH_STATUS|$NOTE")

    print_line
done

echo
echo "================ FINAL TEST RESULTS ================"
printf "%-18s %-14s %-10s %-10s %-30s\n" "IP" "USERNAME" "PING" "SSH" "NOTE"
printf "%-18s %-14s %-10s %-10s %-30s\n" "-----------------" "-------------" "--------" "--------" "------------------------------"

for row in "${RESULTS[@]}"; do
    IFS='|' read -r ip user ping_status ssh_status note <<< "$row"
    printf "%-18s %-14s %-10s %-10s %-30s\n" "$ip" "$user" "$ping_status" "$ssh_status" "$note"
done

echo "===================================================="

