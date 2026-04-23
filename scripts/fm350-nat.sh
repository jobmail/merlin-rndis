#!/bin/sh

WAN_IF="${1:-eth3}"

log_message() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" | tee -a $LOG_FILE
    logger -t "FM350" "$msg"
}

    log_message "Configuring NAT rules..."

    iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
