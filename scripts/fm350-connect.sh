#!/bin/sh

SCRIPT_NAME=$(basename "$0")
GUARD_FILE="/jffs/fm350.reboot"
MODEM_TTY="/dev/ttyUSB4"
WAN_IF="eth3"
LOG_FILE="/tmp/fm350.log"
APN="internet"

MODEM_READY_TIMEOUT=30
MODEM_RESET_TIMEOUT=60

log_message() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" | tee -a $LOG_FILE
    logger -t "FM350" "$msg"
}

wait_for_modem_ready() {
    local tty="$1"
    local timeout="${2:-$MODEM_READY_TIMEOUT}"
    local waited=0

    log_message "Waiting for modem to become ready on $tty (timeout ${timeout}s)..."

    while [ $waited -lt $timeout ]; do
        if [ ! -c "$tty" ]; then
            sleep 2
            waited=$((waited + 2))
            continue
        fi

        if send_at_silent "AT" 3; then
            log_message "Modem is ready and responding to AT commands."
            return 0
        fi

        sleep 2
        waited=$((waited + 3))
    done

    log_message "ERROR: Modem did not respond to AT within ${timeout}s."
    return 1
}

reset_modem() {
    log_message "Attempting full software reset (AT+CFUN=1,1)..."

    if [ ! -c "$MODEM_TTY" ]; then
        log_message "ERROR: $MODEM_TTY is not a character device (modem detached or hung)"
        return 1
    fi

    log_message "Stopping network interface..."
    ifconfig $WAN_IF down 2>/dev/null
    ip route flush dev $WAN_IF 2>/dev/null

    sleep 2

    printf "%s\r" "AT+CFUN=1,1" > "$MODEM_TTY"

    log_message "  -> Waiting for modem to reboot ($MODEM_READY_TIMEOUT seconds)..."
    sleep $MODEM_READY_TIMEOUT

    local waited=0
    while [ ! -c "$MODEM_TTY" ] && [ $waited -lt $MODEM_RESET_TIMEOUT ]; do
        sleep 2
        waited=$((waited + 2))
    done

    if [ ! -c "$MODEM_TTY" ]; then
        log_message "ERROR: Modem TTY port did not reappear after reset"
        return 1
    fi

    log_message "  -> Modem TTY port reappeared"

    sleep 5
    if ! wait_for_modem_ready "$MODEM_TTY" "$MODEM_READY_TIMEOUT"; then
        log_message "ERROR: Modem not responding after reset"
        return 1
    fi

    log_message "Software reset completed successfully."
    return 0
}

write_at() {
    local cmd="$1"
    local write_timeout="${2:-2}"
    local silent_mode="${3:-0}"

    [ "$silent_mode" != "1" ] && log_message "  -> Sending: $cmd"

    {
        printf "%s\r" "$cmd" > "$MODEM_TTY"
    } &
    local write_pid=$!

    local waited=0
    while kill -0 $write_pid 2>/dev/null && [ $waited -lt $write_timeout ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 $write_pid 2>/dev/null; then
        kill -9 $write_pid 2>/dev/null
        wait $write_pid 2>/dev/null
        [ "$silent_mode" != "1" ] && log_message "  !! Write to $MODEM_TTY timed out after ${write_timeout}s"
        return 1
    else
        wait $write_pid 2>/dev/null
        return 0
    fi
}

read_at() {
    local read_timeout="${1:-5}"
    local silent_mode="${2:-0}"

    local tmp_file="/tmp/at_response_$$.txt"
    cat < "$MODEM_TTY" > "$tmp_file" 2>&1 &
    local cat_pid=$!

    local waited=0
    local result=""

    while [ $waited -lt $read_timeout ]; do
        response=$(cat "$tmp_file" 2>/dev/null)

        if echo "$response" | grep -q "OK"; then
            result="OK"
            [ "$silent_mode" != "1" ] && log_message "  <- Got OK after ${waited}s"
            break
        fi

        if echo "$response" | grep -qE "ERROR|CME ERROR"; then
            result="ERROR"
            [ "$silent_mode" != "1" ] && log_message "  <- Got ERROR after ${waited}s"
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    kill $cat_pid 2>/dev/null
    wait $cat_pid 2>/dev/null

    response=$(cat "$tmp_file" 2>/dev/null)
    rm -f "$tmp_file"

    if [ -n "$response" ]; then
        local first_line=$(echo "$response" | head -1 | tr -d '\r')
        [ "$silent_mode" != "1" ] && log_message "  <- Response: $first_line"
    else
        [ "$silent_mode" != "1" ] && log_message "  <- Response: (empty)"
    fi

    echo "$response"

    case "$result" in
        "OK") return 0 ;;
        "ERROR") return 1 ;;
        *) return 2 ;;
    esac
}

send_at() {
    local cmd="$1"
    local timeout_sec="${2:-5}"
    local silent_mode="${3:-0}"

    if ! write_at "$cmd" 2 "$silent_mode"; then
        [ "$silent_mode" != "1" ] && log_message "  !! Write failed, aborting"
        return 1
    fi

    read_at "$timeout_sec" "$silent_mode"
    return $?
}

send_at2() {
    local cmd="$1"
    local timeout_sec="${2:-5}"
    local silent_mode="${3:-0}"

    [ "$silent_mode" != "1" ] && log_message "  -> Sending: $cmd"

    if [ ! -c "$MODEM_TTY" ]; then
        log_message "ERROR: $MODEM_TTY is not a character device (modem detached or hung)"
        return 1
    fi

    printf "%s\r" "$cmd" > "$MODEM_TTY"

    local tmp_file="/tmp/at_response_$$.txt"
    cat < "$MODEM_TTY" > "$tmp_file" 2>&1 &
    local cat_pid=$!

    local waited=0
    local result=""

    while [ $waited -lt $timeout_sec ]; do
        response=$(cat "$tmp_file" 2>/dev/null)

        if echo "$response" | grep -q "OK"; then
            result="OK"
            [ "$silent_mode" != "1" ] && log_message "  <- Got OK after ${waited}s"
            break
        fi

        if echo "$response" | grep -qE "ERROR|CME ERROR"; then
            result="ERROR"
            [ "$silent_mode" != "1" ] && log_message "  <- Got ERROR after ${waited}s"
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    kill $cat_pid 2>/dev/null
    wait $cat_pid 2>/dev/null

    response=$(cat "$tmp_file" 2>/dev/null)
    rm -f "$tmp_file"

    if [ -n "$response" ]; then
        if [ "$silent_mode" != "1" ]; then
            local first_line=$(echo "$response" | head -1 | tr -d '\r')
            log_message "  <- Response: $first_line"
        fi
    else
        [ "$silent_mode" != "1" ] && log_message "  <- Response: (empty)"
    fi

    echo "$response"

    [ "$result" = "ERROR" ] && return 1
    return 0
}

send_at_silent() {
    send_at "$1" "$2" "1" > /dev/null 2>&1
    return $?
}

test_at_response_error() {
    echo "$1" | grep -qE "ERROR|CME ERROR"
    return $?
}

check_modem_health() {
    local ERROR_COUNT=0

    if [ ! -e "$MODEM_TTY" ]; then
        log_message "WATCHDOG: $MODEM_TTY does not exist"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi

    if [ ! -c "$MODEM_TTY" ]; then
        log_message "WATCHDOG: $MODEM_TTY is not a character device (modem detached or hung)"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi

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

    if [ $ERROR_COUNT -gt 1 ]; then
        log_message "WATCHDOG: Health check failed with $ERROR_COUNT errors"
        return 1
    fi

    return 0
}

watchdog_loop() {
    local check_interval=60

    while true; do
        sleep $check_interval

        if ! check_modem_health; then
            log_message "WATCHDOG: Modem problem detected, attempting recovery..."

            if reset_modem; then
                continue
            fi

            log_message "WATCHDOG: All recovery attempts failed. Rebooting router in 10 seconds..."
            sleep 10
            reboot
        fi
    done
}

main() {

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

    log_message "=========================================="
    log_message "FM350 Connection Script v10"
    log_message "=========================================="

    if ! wait_for_modem_ready "$MODEM_TTY" 5; then
        log_message "Modem not ready. Trying a reset..."
        if [ -c "$MODEM_TTY" ]; then
            reset_modem || exit 1
        else
            log_message "ERROR: $MODEM_TTY not found."

	    watchdog_loop &            
	    exit 1
        fi
    fi

    stty -F "$MODEM_TTY" raw -icanon -echo min 1 time 5 2>/dev/null
    log_message "Serial port configured."

    log_message "Configuring modem echo and error reporting..."
    send_at_silent "ATE1" 1
    log_message "  -> Echo enabled"
    send_at_silent "AT+CMEE=2" 1
    log_message "  -> Verbose error reporting enabled"

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

    local isFM350_GL_16=0
    if echo "$firmwareVer" | grep -q "^11600"; then
        isFM350_GL_16=1
        log_message "Detected: FM350GL-16 variant"
    else
        log_message "Detected: Standard FM350 variant"
    fi

    log_message ""
    log_message "=== Checking SIM card ==="
    local cpin_response=$(send_at "AT+CPIN?" 2)
    if ! echo "$cpin_response" | grep -q "+CPIN: READY"; then
        log_message "ERROR: SIM card is not ready"
        log_message "Response: $cpin_response"
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

    local preferredBands="20,6,3,0" #"20,6,3,2,1,107,103,0"
    if [ $isFM350_GL_16 -eq 1 ]; then
        preferredBands="4,3,2,0"
    fi
    log_message "Setting preferred bands: $preferredBands"
    response=$(send_at "AT+GTACT=$preferredBands" 3)
    if test_at_response_error "$response"; then
        log_message "ERROR: Failed to setup preferred bands"
        log_message "Response: $response"
        reset_modem || exit 1
    fi
    log_message "  -> Bands configured successfully"

    sleep 3

    log_message "Registering on network (COPS=0)..."
    response=$(send_at "AT+COPS=0" 60)
    if test_at_response_error "$response"; then
        log_message "ERROR: Failed to register on the network"
        log_message "Response: $response"
        reset_modem || exit 1
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
        reset_modem || exit 1
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
            log_message "Response: $response"
            reset_modem || exit 1
        fi
        log_message "  -> PDP context activated"
        sleep 2
    fi

    log_message ""
    log_message "=== Getting IP configuration ==="
    response=$(send_at "AT+CGPADDR=1; +GTDNS=1" 3)

    if ! test_at_response_error "$response"; then
        local ip_addr=$(echo "$response" | grep "+CGPADDR:" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -z "$ip_addr" ]; then
            log_message "ERROR: Failed to extract IP address"
            reset_modem || exit 1
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
	    else
	    	log_message "WARNING: Guard file $GUARD_FILE does not exist. Watchdog may not be working correctly."
	    fi

            watchdog_loop &
        else
            log_message "WARNING: Ping to 8.8.8.8 failed"
        fi
    else
        log_message "ERROR: Failed to get IP configuration"
        reset_modem || exit 1
    fi

    service restart_nat > /dev/null 2>&1
    service restart_firewall > /dev/null 2>&1

    log_message "=========================================="
    log_message "SUCCESS: Connection fully established!"
    log_message "=========================================="
    exit 0
}

main "$@"
