#!/bin/sh

WAN_IF="${1:-eth3}"

log_message() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" | tee -a $LOG_FILE
    logger -t "FM350" "$msg"
}

    log_message "Configuring Firewall rules..."

    iptables -D FORWARD -i br0 -o "$WAN_IF" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$WAN_IF" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -I FORWARD -i br0 -o "$WAN_IF" -j ACCEPT
    iptables -I FORWARD -i "$WAN_IF" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
