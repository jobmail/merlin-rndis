#!/bin/sh

. /jffs/scripts/fm350-lib.sh

log_message "Configuring NAT rules for $WAN_IF..."

iptables -t nat -D POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
