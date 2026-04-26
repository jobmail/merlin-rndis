#!/bin/sh

. /jffs/scripts/fm350-lib.sh

log_message "Configuring Firewall rules for $WAN_IF..."

iptables -D FORWARD -i br0 -o "$WAN_IF" -j ACCEPT 2>/dev/null
iptables -D FORWARD -i "$WAN_IF" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -I FORWARD -i br0 -o "$WAN_IF" -j ACCEPT
iptables -I FORWARD -i "$WAN_IF" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
