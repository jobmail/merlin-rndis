#!/bin/sh

. /jffs/scripts/fm350-lib.sh

UNIT="${1:-0}"

wait_for_registration() {
    local max_attempts=30
    local attempt=0
    
    log_message "Waiting for network registration..."
    
    # Быстрая проверка — может, модем уже зарегистрирован?
    local cereg=$(send_at "AT+CEREG?" 3 | grep "+CEREG:" | cut -d, -f2 | xargs)
    local cgreg=$(send_at "AT+CGREG?" 3 | grep "+CGREG:" | cut -d, -f2 | xargs)
    
    if [ "$cereg" = "1" ] || [ "$cereg" = "5" ] || [ "$cgreg" = "1" ] || [ "$cgreg" = "5" ]; then
        log_message "  -> Already registered (CEREG=$cereg, CGREG=$cgreg)!"
        return 0
    fi
    
    sleep 3

    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        cereg=$(send_at "AT+CEREG?" 3 | grep "+CEREG:" | cut -d, -f2 | xargs)
        cgreg=$(send_at "AT+CGREG?" 3 | grep "+CGREG:" | cut -d, -f2 | xargs)
        
        if [ "$cereg" = "3" ] || [ "$cgreg" = "3" ]; then
            log_message "ERROR: Registration DENIED (CEREG=$cereg, CGREG=$cgreg)"
            return 1
        fi
        
        if [ "$cereg" = "1" ] || [ "$cereg" = "5" ] || [ "$cgreg" = "1" ] || [ "$cgreg" = "5" ]; then
            log_message "  -> Registered (CEREG=$cereg, CGREG=$cgreg, attempt $attempt)"
            return 0
        fi
        
        if [ $((attempt % 5)) -eq 0 ]; then
            log_message "Still searching... (attempt $attempt/$max_attempts, CEREG=$cereg)"
        fi
        
        sleep 2
    done
    
    log_message "ERROR: Registration timeout after $((max_attempts * 2)) seconds"
    return 1
}

initialize_connection() {
    log_message ""
    log_message "=== Initializing connection ==="

    stop_interface

    log_message "Checking functional mode..."
    local cfun=$(send_at "AT+CFUN?" 3 | grep "+CFUN:" | cut -d: -f2 | tr -d '  \r\n')
    if [ "$cfun" != "1" ]; then
        log_message "  -> CFUN=$cfun, setting full functionality (CFUN=1)..."
        if ! send_at "AT+CFUN=1" 10; then
            log_message "ERROR: Failed to set CFUN=1"
            return 1
        fi
        log_message "  -> Waiting for modem to apply settings..."
        sleep 5
    else
        log_message "  -> CFUN already 1 (full functionality)"
    fi   
    
    log_message "Configuring URC and output formats..."
    send_at_silent "AT+CGPIAF=1,0,0,0" 1
    log_message "  -> IP format: standard decimal"
    send_at_silent "AT+CREG=2" 1
    send_at_silent "AT+CGREG=2" 1
    send_at_silent "AT+CEREG=2" 1
    log_message "  -> Registration URCs enabled with full info (+CREG/+CGREG/+CEREG=2)"
    send_at_silent "AT+COPS=3,0" 1
    log_message "  -> Operator name format: long alphanumeric"

    log_message "Registering on network..."
    local cops=$(send_at "AT+COPS?" 3 | grep "+COPS:" | cut -d: -f2 | cut -d, -f1 | tr -d '  \r\n')
    if [ "$cops" = "0" ]; then
        log_message "  -> COPS mode is AUTO"
    else
        log_message "  -> COPS mode is $cops, switching to AUTO"
        for try in 1 2 3; do
            response=$(send_at "AT+COPS=0" 5)
            if ! test_at_response_error "$response"; then
                log_message "  -> AUTO mode set (attempt $try)"
                break
            fi
            log_message "  -> Attempt $try failed, retrying..."
            sleep 2
        done
        if test_at_response_error "$response"; then
            log_message "ERROR: Failed to set COPS=0 after 3 attempts"
            return 1
        fi
    fi

    log_message "Setting APN..."
    if [ -z "$APN" ]; then
        log_message "WARNING: APN not set, using default from modem"
    else
        local current_apn=$(send_at "AT+CGDCONT?" 3 | grep "+CGDCONT: 1," | cut -d'"' -f4)
        if [ "$current_apn" = "$APN" ]; then
            log_message "  -> APN already correct: $APN"
        else
            log_message "  -> APN mismatch: current='$current_apn', setting to '$APN'"
            if ! send_at "AT+CGDCONT=1,\"IPV4V6\",\"$APN\"" 5; then
                log_message "ERROR: Failed to set APN"
                return 1
            fi
            log_message "  -> APN updated, PDP context will be re-created"
            APN_CHANGED=1
        fi
    fi

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

    wait_for_registration || return 1

    cgatt=$(send_at "AT+CGATT?" 3 | grep "+CGATT:" | cut -d: -f2 | tr -d '  \r\n')
    if [ -z "$cgatt" ]; then
        log_message "WARNING: No response from AT+CGATT? (modem busy)"
        log_message "  -> Proceeding with PDP activation anyway..."
    elif [ "$cgatt" = "0" ]; then
        log_message "GPRS not attached, attaching..."
        if ! send_at "AT+CGATT=1" 10; then
            log_message "WARNING: GPRS attach command failed"
        fi
    elif [ "$cgatt" = "1" ]; then
        log_message "GPRS already attached"
    fi

    cgact=$(send_at "AT+CGACT?" 3 | grep "+CGACT: 1," | cut -d, -f2 | tr -d '  \r\n')
    if [ "$APN_CHANGED" = "1" ] && [ "$cgact" = "1" ]; then
        log_message "APN changed, deactivating old PDP context..."
        send_at "AT+CGACT=0,1" 5
        cgact="0"
    fi

    if [ "$cgact" = "1" ]; then
        log_message "PDP context already active, skipping activation"
    else
        local pdp_retry=3
        while [ $pdp_retry -gt 0 ]; do
            log_message "Activating PDP context (attempt $((4 - pdp_retry))/3)..."
            response=$(send_at "AT+CGACT=1,1" 15)
            if ! test_at_response_error "$response"; then
                log_message "  -> PDP context activated"
                break
            fi
            
            pdp_retry=$((pdp_retry - 1))
            if [ $pdp_retry -gt 0 ]; then
                log_message "  -> Activation failed, retrying in 3 seconds..."
                sleep 3
            else
                log_message "ERROR: Failed to activate PDP context after 3 attempts"
                return 1
            fi
        done
    fi

    log_message ""
    log_message "=== Getting IP configuration ==="

    local ip_addr=""
    local ip_dns1=""
    local ip_dns2=""

    for attempt in 1 2 3; do
        log_message "Getting IP configuration (attempt $attempt/3)..."
        
        response=$(send_at "AT+CGPADDR=1; +GTDNS=1" 10)

        if test_at_response_error "$response"; then
            log_message "  -> Failed to get IP configuration"
            [ $attempt -lt 3 ] && sleep 3
            continue
        fi

        local ip_full=$(echo "$response" | grep "+CGPADDR: 1," | cut -d'"' -f2)
        if [ -n "$ip_full" ]; then
            ip_addr=$(echo "$ip_full" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            [ -z "$ip_addr" ] && ip_addr=$(echo "$ip_full" | awk '{print $1}')
        fi

        local dns_line=$(echo "$response" | grep "+GTDNS: 1,")
        if [ -n "$dns_line" ]; then
            ip_dns1=$(echo "$dns_line" | cut -d'"' -f2)
            ip_dns2=$(echo "$dns_line" | cut -d'"' -f4)
        fi

        [ -n "$ip_addr" ] && break
    done

    if [ -z "$ip_addr" ]; then
        log_message "ERROR: Failed to extract IP address after 3 attempts"
        return 1
    fi

    [ -z "$ip_dns1" ] && ip_dns1="8.8.8.8"
    [ -z "$ip_dns2" ] && ip_dns2="8.8.4.4"

    local ip_gw=$(echo "$ip_addr" | awk -F. '{print $1"."$2"."$3".1"}')
    local ip_mask="255.255.255.0"

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

    nvram set "wan${UNIT}_proto=static"
    nvram set "wan${UNIT}_ipaddr"="$ip_addr"
    nvram set "wan${UNIT}_gateway"="$ip_gw"
    nvram set "wan${UNIT}_dns"="$ip_dns1 $ip_dns2"
    nvram set "link_wan${UNIT}"=1
    nvram set "wan${UNIT}_state_t"=2
    nvram set "wan${UNIT}_auxstate_t"=0
    nvram set "wan${UNIT}_sbstate_t"=0
    nvram set "wan${UNIT}_is_usb_modem_ready"=1
    
    nvram commit

    #service restart_dnsmasq > /dev/null 2>&1
    #service restart_nat > /dev/null 2>&1
    #service restart_firewall > /dev/null 2>&1

    do_start fm350-nat.sh
    do_start fm350-firewall.sh

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
    local current_type=$(nvram get usb_modem_act_type)
    if [ "$current_type" != "rndis" ]; then
        local modem_found=0
        for device_path in /sys/bus/usb/devices/[0-9]*-*; do
            [ -f "$device_path/idVendor" ] || continue
            vid=$(cat "$device_path/idVendor" 2>/dev/null)
            if [ "$vid" = "2cb7" ] || [ "$vid" = "0e8d" ]; then
                modem_found=1
                break
            fi
        done
        
        if [ "$modem_found" -eq 1 ]; then
            log_message "Setting NVRAM variables..."
            nvram set usb_modem_act_type=rndis
            nvram commit
            log_message "usb_modem_act_type set to rndis"
        else
            log_message "WARNING: Modem not found on USB bus, keeping usb_modem_act_type=$current_type"
        fi
    fi

    log_message "=========================================="
    log_message "FM350 Connection Script v1.0.0 (c) Refresh"
    log_message "=========================================="

    if ! wait_for_modem_ready "$MODEM_TTY"; then
        log_message "Modem not ready. Trying a reset..."
        do_start fm350-watchdog.sh check
        exit 1
    fi

    stty -F "$MODEM_TTY" raw -icanon -echo min 0 time 5 2>/dev/null
    log_message "Serial port configured"

    log_message "Configuring modem echo and error reporting..."
    send_at_silent "ATE0" 5
    send_at_silent "AT+CMEE=2" 5

    log_message ""
    log_message "=== Getting modem information ==="
    local response=$(send_at "AT+CGMI?; +FMM?; +GTPKGVER?; +CFSN?; +CGSN?" 5)

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
        do_start fm350-watchdog.sh check
        exit 1
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
        do_start fm350-watchdog.sh
        exit 0
    else
        do_start fm350-watchdog.sh check
    fi
    exit 1
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