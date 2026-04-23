#!/bin/sh

SCRIPT_NAME=$(basename "$0")
. /jffs/scripts/fm350-lib.sh

old_pids=$(ps w | grep "$SCRIPT_NAME" | grep -v grep | grep -v "$$" | awk '{print $1}')
if [ -n "$old_pids" ]; then
    log_message "Found old instances with PIDs: $old_pids"
    for pid in $old_pids; do
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
    done
    sleep 1
    for pid in $old_pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
    done
    log_message "Old instances terminated"
fi

check_modem_health() {
    local ERROR_COUNT=0
    [ ! -e "$MODEM_TTY" ] && { log_message "WATCHDOG: $MODEM_TTY does not exist"; ERROR_COUNT=$((ERROR_COUNT + 1)); }
    [ ! -c "$MODEM_TTY" ] && { log_message "WATCHDOG: $MODEM_TTY is not a character device"; ERROR_COUNT=$((ERROR_COUNT + 1)); }
    if ! send_at_silent "AT" 3; then
        log_message "WATCHDOG: AT port check failed"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    if ! ip addr show "$WAN_IF" 2>/dev/null | grep -q "inet "; then
        log_message "WATCHDOG: Interface $WAN_IF has no IP address"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    if ! ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
        log_message "WATCHDOG: Ping to 8.8.8.8 failed"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    if [ $ERROR_COUNT -ge 0 ]; then
        log_message "WATCHDOG: Health check failed with $ERROR_COUNT errors"
        return 1
    fi

    return 0
}

recover_connection() {
    log_message "WATCHDOG: Attempting to recover connection..."
    if reset_modem; then
        log_message "WATCHDOG: Modem reset successful, re-initializing..."
        if initialize_connection; then
            return 0
        fi
    fi
    log_message "WATCHDOG: Recovery failed, scheduling delayed reboot via guard..."
    /jffs/scripts/fm350-guard.sh now &
    return 1
}

initialize_connection() {
    log_message ""
    log_message "=== Initializing connection ==="

    send_at_silent "AT+CFUN=1" 2
    send_at_silent "AT+CGPIAF=1,0,0,0" 1
    send_at_silent "AT+CREG=0" 1
    send_at_silent "AT+CGREG=0" 1
    send_at_silent "AT+CEREG=0" 1
    send_at_silent "AT+CGATT=0" 2
    send_at_silent "AT+COPS=2" 1
    send_at_silent "AT+COPS=3,0" 1
    send_at_silent "AT+CGDCONT=0,\"IPV4V6\"" 1
    send_at_silent "AT+CGDCONT=1,\"IPV4V6\",\"$APN\"" 1

    local preferredBands="20,6,3,0"
    if [ "$IS_FM350_GL_16" = "1" ]; then
        preferredBands="4,3,2,0"
    fi
    log_message "Setting preferred bands: $preferredBands"
    response=$(send_at "AT+GTACT=$preferredBands" 3)
    if test_at_response_error "$response"; then
        log_message "ERROR: Failed to setup preferred bands"
        return 1
    fi
    log_message "  -> Bands configured successfully"

    sleep 3

    log_message "Registering on network (COPS=0)..."
    response=$(send_at "AT+COPS=0" 60)
    if test_at_response_error "$response"; then
        log_message "ERROR: Failed to register on the network"
        return 1
    fi

    log_message "Waiting for packet network registration..."
    local reg_ready=0
    local attempts=30
    while [ $attempts -gt 0 ]; do
        response=$(send_at "AT+CGREG?" 1)
        local cgreg_stat=$(echo "$response" | grep "+CGREG:" | cut -d, -f2 | xargs)
        if [ "$cgreg_stat" = "1" ] || [ "$cgreg_stat" = "5" ]; then
            reg_ready=1
            log_message "  -> Packet network ready (CGREG: $cgreg_stat)"
            break
        fi
        sleep 2
        attempts=$((attempts - 1))
    done

    if [ $reg_ready -eq 0 ]; then
        log_message "ERROR: Packet network not ready after 60 seconds"
        return 1
    fi

    send_at_silent "AT+CGATT=1" 5

    response=$(send_at "AT+CGACT?" 1)
    local pdp_status=$(echo "$response" | sed -n 's/.*+CGACT: \([0-9]\).*/\1/p' | head -1)
    if [ "$pdp_status" = "1" ]; then
        log_message "PDP context already active, skipping activation"
    else
        response=$(send_at "AT+CGACT=1,1" 10)
        if test_at_response_error "$response"; then
            log_message "ERROR: Failed to activate PDP context"
            return 1
        fi
        log_message "  -> PDP context activated"
        sleep 2
    fi

    log_message ""
    log_message "=== Getting IP configuration ==="
    response=$(send_at "AT+CGPADDR=1; +GTDNS=1" 3)

    if test_at_response_error "$response"; then
        log_message "ERROR: Failed to get IP configuration"
        return 1
    fi

    local ip_addr=$(echo "$response" | grep "+CGPADDR:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$ip_addr" ]; then
        log_message "ERROR: Failed to extract IP address"
        return 1
    fi

    local ip_gw=$(echo "$ip_addr" | awk -F. '{print $1"."$2"."$3".1"}')
    local ip_mask="255.255.255.0"

    local ip_dns1=$(echo "$response" | grep "+GTDNS:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p')
    local ip_dns2=$(echo "$response" | grep "+GTDNS:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed -n '2p')

    [ -z "$ip_dns1" ] && ip_dns1="8.8.8.8"
    [ -z "$ip_dns2" ] && ip_dns2="8.8.4.4"

    log_message "IP Address: $ip_addr"
    log_message "Gateway: $ip_gw"
    log_message "DNS: $ip_dns1, $ip_dns2"

    ifconfig "$WAN_IF" down 2>/dev/null
    ifconfig "$WAN_IF" up
    ifconfig "$WAN_IF" "$ip_addr" netmask "$ip_mask"
    ip route del default 2>/dev/null
    ip route add default via "$ip_gw" dev "$WAN_IF"

    echo "nameserver $ip_dns1" > /tmp/resolv.conf
    echo "nameserver $ip_dns2" >> /tmp/resolv.conf
    echo "server=$ip_dns1" > /tmp/resolv.dnsmasq
    echo "server=$ip_dns2" >> /tmp/resolv.dnsmasq

    service restart_dnsmasq > /dev/null 2>&1

    /jffs/scripts/fm350-nat.sh "$WAN_IF"
    /jffs/scripts/fm350-firewall.sh "$WAN_IF"

    if ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
        log_message "SUCCESS: Internet is reachable!"

        nvram set wan0_ifname="$WAN_IF"
        nvram set wan_ifnames="$WAN_IF"
        nvram set wan0_ipaddr="$ip_addr"
        nvram set wan_ipaddr="$ip_addr"
        nvram set wan0_dns="$ip_dns1 $ip_dns2"
        nvram set wan_dns="$ip_dns1 $ip_dns2"
        nvram set link_wan=1
        nvram set wan0_state_t=2
        nvram set wan_state_t=2
        nvram set wan0_auxstate_t=0
        nvram set wan0_sbstate_t=0

        local NTP_SERVER=$(nvram get ntp_server0)
        [ -z "$NTP_SERVER" ] && NTP_SERVER="pool.ntp.org"
        ntpd -t -S /sbin/ntpd_synced -p "$NTP_SERVER"

        if [ -f "$GUARD_FILE" ]; then
            log_message "Removing temporary guard file"
            rm -f "$GUARD_FILE"
        fi

        return 0
    else
        log_message "WARNING: Ping to 8.8.8.8 failed"
        return 1
    fi
}

main() {
    log_message "=========================================="
    log_message "FM350 Connection Script v11"
    log_message "=========================================="

    if ! wait_for_modem_ready "$MODEM_TTY" 5; then
        log_message "Modem not ready. Trying a reset..."
        if [ -c "$MODEM_TTY" ]; then
            reset_modem || exit 1
        else
            log_message "ERROR: $MODEM_TTY not found."
            exit 1
        fi
    fi

    stty -F "$MODEM_TTY" raw -icanon -echo min 1 time 5 2>/dev/null
    log_message "Serial port configured."

    log_message "Configuring modem echo and error reporting..."
    send_at_silent "ATE1" 1
    send_at_silent "AT+CMEE=2" 1

    log_message ""
    log_message "=== Getting modem information ==="
    local response=$(send_at "AT+CGMI?; +FMM?; +GTPKGVER?; +CFSN?; +CGSN?" 3)

    local manufacturer=$(echo "$response" | grep "+CGMI:" | cut -d: -f2 | tr -d '"' | xargs)
    local model=$(echo "$response" | grep "+FMM:" | cut -d: -f2 | tr -d '"' | xargs)
    local firmwareVer=$(echo "$response" | grep "+GTPKGVER:" | cut -d: -f2 | tr -d '"' | xargs)
    local serialNumber=$(echo "$response" | grep "+CFSN:" | cut -d: -f2 | tr -d '"' | xargs)
    local imei=$(echo "$response" | grep "+CGSN:" | cut -d: -f2 | tr -d '"' | xargs)

    log_message "Manufacturer: $manufacturer"
    log_message "Model: $model"
    log_message "Firmware: $firmwareVer"
    log_message "Serial: $serialNumber"
    log_message "IMEI: $imei"

    IS_FM350_GL_16=0
    if echo "$firmwareVer" | grep -q "^11600"; then
        IS_FM350_GL_16=1
        log_message "Detected: FM350GL-16 variant"
    else
        log_message "Detected: Standard FM350 variant"
    fi

    log_message ""
    log_message "=== Checking SIM card ==="
    local cpin_response=$(send_at "AT+CPIN?" 2)
    if ! echo "$cpin_response" | grep -q "+CPIN: READY"; then
        log_message "ERROR: SIM card is not ready"
        reset_modem || exit 1
    fi
    log_message "SIM card status: READY"

    log_message ""
    log_message "=== Getting SIM identifiers ==="
    response=$(send_at "AT+CIMI?; +CCID?" 2)
    local imsi=$(echo "$response" | grep "+CIMI:" | cut -d: -f2 | tr -d '"' | xargs)
    local ccid=$(echo "$response" | grep "+CCID:" | cut -d: -f2 | tr -d '"' | xargs)
    log_message "IMSI: $imsi"
    log_message "ICCID: $ccid"

    if initialize_connection; then
        log_message "=========================================="
        log_message "SUCCESS: Connection fully established!"
        log_message "=========================================="
        ( watchdog_loop ) < /dev/null > /dev/null 2>&1 &
        exit 0
    else
        log_message "ERROR: Connection initialization failed"
        reset_modem || exit 1
    fi
}

watchdog_loop() {
    local check_interval=60
    while true; do
        sleep $check_interval
        if ! check_modem_health; then
            recover_connection
        fi
    done
}

main "$@"
