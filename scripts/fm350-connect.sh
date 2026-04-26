#!/bin/sh

. /jffs/scripts/fm350-lib.sh

UNIT="${1:-0}"

initialize_connection() {
    log_message ""
    log_message "=== Initializing connection ==="

    stop_interface
    send_at_silent "AT+CFUN=1" 5
    send_at_silent "AT+CGPIAF=1,0,0,0" 5
    send_at_silent "AT+CREG=0" 5
    send_at_silent "AT+CGREG=0" 5
    send_at_silent "AT+CEREG=0" 5
    send_at_silent "AT+CGATT=0" 5
    send_at_silent "AT+CGACT=0,1" 5
    send_at_silent "AT+COPS=2" 5
    send_at_silent "AT+COPS=3,0" 5
    send_at_silent "AT+CGDCONT=0,\"IPV4V6\"" 5
    send_at_silent "AT+CGDCONT=1,\"IPV4V6\",\"$APN\"" 5

    if [ "$IS_FM350_GL_16" = "1" ]; then
        PREFERRED_BANDS="4,3,2,0"
    fi
    log_message "Setting preferred bands: $PREFERRED_BANDS"
    response=$(send_at "AT+GTACT=$PREFERRED_BANDS" 5)
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
        response=$(send_at "AT+CGREG?" 5)
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

    response=$(send_at "AT+CGACT?" 5)
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
    response=$(send_at "AT+CGPADDR=1; +GTDNS=1" 10)

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

    case "$WANS_DUALWAN" in
    "usb none"|"usb wan")
        ip route del default 2>/dev/null
        ip route add default via "$ip_gw" dev "$WAN_IF"
        log_message "Default route set via $WAN_IF gw $ip_gw"
        ;;
    "wan usb")
        # USB — резервный, сохраняем для failback, но маршрут не трогаем
        log_message "USB modem is backup WAN, skipping default route"
        ;;
    *)
        log_message "Unknown wans_dualwan: $WANS_DUALWAN, skipping default route"
        ;;
    esac

    nvram set "wan${UNIT}_ipaddr"="$ip_addr"
    nvram set "wan${UNIT}_gateway"="$ip_gw"
    nvram set "wan${UNIT}_dns"="$ip_dns1 $ip_dns2"
    nvram set "link_wan${UNIT}"=1
    nvram set "wan${UNIT}_state_t"=2
    nvram set "wan${UNIT}_auxstate_t"=0
    nvram set "wan${UNIT}_sbstate_t"=0
    nvram set "wan${UNIT}_is_usb_modem_ready"=1
    nvram commit

    service restart_dnsmasq > /dev/null 2>&1
    service restart_nat > /dev/null 2>&1
    service restart_firewall > /dev/null 2>&1

    #/jffs/scripts/fm350-nat.sh "$WAN_IF"
    #/jffs/scripts/fm350-firewall.sh "$WAN_IF"

    kill -SIGUSR2 $(cat /var/run/wanduck.pid)
    sleep 1

    if ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
        log_message "Internet is reachable!"

        local NTP_SERVER=$(nvram get ntp_server0)
        [ -z "$NTP_SERVER" ] && NTP_SERVER="pool.ntp.org"
        killall ntpd 2>/dev/null
        ntpd -t -S /sbin/ntpd_synced -p "$NTP_SERVER"

        if [ -f "$GUARD_FILE" ]; then
            log_message "Removing temporary guard file"
            rm -f "$GUARD_FILE"
        fi

        log_message "=========================================="
        log_message "SUCCESS: Connection fully established!"
        log_message "=========================================="

        return 0
    else
        log_message "WARNING: Ping to 8.8.8.8 failed"
        log_message "ERROR: Connection initialization failed"
        
        return 1
    fi
}

connect() {
    log_message "=========================================="
    log_message "FM350 Connection Script v1.0 (c) Refresh  "
    log_message "=========================================="

    if ! wait_for_modem_ready "$MODEM_TTY"; then
        log_message "Modem not ready. Trying a reset..."
        if [ -c "$MODEM_TTY" ]; then
            reset_modem || exit 1
        else
            log_message "ERROR: $MODEM_TTY not found"
            /jffs/scripts/fm350-watchdog.sh &
            exit 1
        fi
    fi

    stty -F "$MODEM_TTY" raw -icanon -echo min 0 time 5 2>/dev/null
    log_message "Serial port configured"

    log_message "Configuring modem echo and error reporting..."
    send_at_silent "ATE0" 5
    send_at_silent "AT+CMEE=2" 5

    log_message ""
    log_message "=== Getting modem information ==="
    local response=$(send_at "AT+CGMI?; +FMM?; +GTPKGVER?; +CFSN?; +CGSN?" 15)

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
    if ! check_sim; then
        reset_modem || exit 1
    fi
    log_message "SIM card status: READY"

    log_message ""
    log_message "=== Getting SIM identifiers ==="
    response=$(send_at "AT+CIMI?; +CCID?" 10)
    local imsi=$(echo "$response" | grep "+CIMI:" | cut -d: -f2 | tr -d '"' | xargs)
    local ccid=$(echo "$response" | grep "+CCID:" | cut -d: -f2 | tr -d '"' | xargs)
    log_message "IMSI: $imsi"
    log_message "ICCID: $ccid"

    if initialize_connection; then
        /jffs/scripts/fm350-watchdog.sh &
        exit 0
    else
        reset_modem || exit 1
    fi
}

main() {
    case "${1:-connect}" in
        reinit)
            initialize_connection
            ;;
        connect|*)
            connect
            ;;
    esac
}

main "$@"