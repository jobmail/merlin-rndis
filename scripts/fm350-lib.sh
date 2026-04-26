SCRIPT_NAME=$(basename "$0")
MODEM_TTY="/dev/ttyUSB4"
WAN_IF=$(nvram get usb_modem_act_dev)
WANS_DUALWAN=$(nvram get wans_dualwan)
LOG_FILE="/tmp/fm350.log"
GUARD_FILE="/jffs/fm350.reboot"

APN="internet"
PREFERRED_BANDS="20,6,3,0"

MODEM_READY_TIMEOUT=30
MODEM_RESET_TIMEOUT=60

stop_lock=`nvram get stop_atlock`
if [ -n "$stop_lock" ] && [ "$stop_lock" -eq "1" ]; then
        AT_LOCK=""
else
        AT_LOCK="flock -x /tmp/at_cmd_lock"
fi

log_message() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" >&2
    echo "[$timestamp] $msg" >> $LOG_FILE
    logger -t "FM350" "$msg"
}

write_at() {
    local cmd="$1"
    local write_timeout="${2:-2}"
    local silent_mode="${3:-0}"

    [ "$silent_mode" != "1" ] && log_message "  -> Sending: $cmd"

    printf "%s\r" "$cmd" > "$MODEM_TTY" &
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

        if echo "$response" | grep -qE "(ERROR|CME ERROR)"; then
            result="ERROR"
            [ "$silent_mode" != "1" ] && log_message "  <- Got ERROR after ${waited}s"
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    kill -9 $cat_pid 2>/dev/null
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

    exec 3>/tmp/at_cmd_lock
    if ! flock -x 3; then
        log_message "FATAL: Could not acquire AT lock within 10s"
        return 1
    fi

    nvram set fm350_busy=1

    if ! write_at "$cmd" 2 "$silent_mode"; then
        [ "$silent_mode" != "1" ] && log_message "  !! Write failed, aborting"
        nvram set fm350_busy=0
        flock -u 3
        exec 3>&-
        return 1
    fi

    read_at "$timeout_sec" "$silent_mode"
    local ret=$?

    nvram set fm350_busy=0
    flock -u 3
    exec 3>&-

    return $ret
}

send_at_silent() {
    send_at "$1" "$2" "1" > /dev/null 2>&1
    return $?
}

test_at_response_error() {
    echo "$1" | grep -qE "ERROR|CME ERROR"
    return $?
}

check_sim() {
    local silent_mode="${1:-0}"

    local cpin_response=$(send_at "AT+CPIN?" 5 "$silent_mode")
    local cpin_ret=$?
    [ $cpin_ret -eq 0 ] || { [ "$silent_mode" != "1" ] && log_message "AT port check failed (no response to AT+CPIN?)"; return 1; }

    local sim_status=$(echo "$cpin_response" | grep "+CPIN:" | cut -d: -f2 | tr -d '\r' | xargs)

    case "$sim_status" in
        "READY")
            return 0
            ;;
    esac

    local err=""
    case "$sim_status" in
        "SIM PIN")              err="SIM card requires PIN code" ;;
        "SIM PUK")              err="SIM card requires PUK code" ;;
        "SIM PIN2")             err="SIM card requires PIN2 code" ;;
        "SIM PUK2")             err="SIM card requires PUK2 code" ;;
        "PH-NET PIN")           err="Network personalization required" ;;
        "PH-NET PUK")           err="Network PUK required" ;;
        "PH-NETSUB PIN")        err="Network subset PIN required" ;;
        "PH-NETSUB PUK")        err="Network subset PUK required" ;;
        "PH-SP PIN")            err="Service provider PIN required" ;;
        "PH-SP PUK")            err="Service provider PUK required" ;;
        "PH-CORP PIN")          err="Corporate PIN required" ;;
        "PH-CORP PUK")          err="Corporate PUK required" ;;
        "SIM ABSENT")           err="SIM card is absent or not detected" ;;
        "NOT READY")            err="SIM card is not ready yet (initializing)" ;;
        *)
            [ -z "$sim_status" ] && err="Could not parse SIM status from response" || err="Unknown SIM status: $sim_status"
            ;;
    esac

    [ -n "$err" ] && [ "$silent_mode" != "1" ] && log_message "$err"

    return 1
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

        if check_sim 1; then
            log_message "Modem is ready and responding to AT commands."
            return 0
        fi

        sleep 2
        waited=$((waited + 3))
    done

    log_message "ERROR: Modem did not respond to AT within ${timeout}s."
    return 1
}

check_modem_health() {
    [ ! -e "$MODEM_TTY" ] && { log_message "WATCHDOG: $MODEM_TTY does not exist"; return 1; }
    [ ! -c "$MODEM_TTY" ] && { log_message "WATCHDOG: $MODEM_TTY is not a character device"; return 1; }
    if ! ip addr show "$WAN_IF" 2>/dev/null | grep -q "inet "; then
        log_message "WATCHDOG: Interface $WAN_IF has no IP address"
        retrun 1
    fi
#    if ! check_sim 1; then
#        log_message "WATCHDOG: AT port check failed"
#        #ERROR_COUNT=$((ERROR_COUNT + 1))
#    fi

    local ping_failed=0
    for i in 1 2 3 4 5; do
        ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 && return 0
        [ "$i" -lt 5 ] && sleep 1
    done

    log_message "WATCHDOG: Ping to 8.8.8.8 failed (5 attempts)"
    return 1
}

stop_interface() {
    log_message "Stopping network interface..."
    ip route flush dev $WAN_IF 2>/dev/null
    ifconfig $WAN_IF down 2>/dev/null
    sleep 1
}

reset_modem() {
    log_message "Attempting full modem reset with USB reinitialization"

    if [ ! -c "$MODEM_TTY" ]; then
        log_message "ERROR: $MODEM_TTY is not a character device (modem detached or hung)"
        return 1
    fi

    stop_interface

    log_message "Attempting modem reset (AT+CFUN=15)..."
    if write_at "AT+CFUN=15" 5 1; then
        log_message "AT+CFUN=15 sent, waiting for modem reboot ($MODEM_READY_TIMEOUT seconds)..."
    else
        log_message "AT+CFUN=15 failed, trying AT+CFUN=1,1..."
        if ! write_at "AT+CFUN=1,1" 5 1; then
            local usb_path=$(nvram get usb_modem_act_path)
            if [ -n "$usb_path" ] && [ -f "/sys/bus/usb/devices/$usb_path/authorized" ]; then
                log_message "Resetting USB device at $usb_path..."
                echo 0 > "/sys/bus/usb/devices/$usb_path/authorized"
                sleep 5
                echo 1 > "/sys/bus/usb/devices/$usb_path/authorized"
                log_message "  -> USB reset complete"
            else
                log_message "WARNING: Could not reset USB device (no authorized file found)"
                return 1
            fi
        fi
    fi

    if ! wait_for_modem_ready "$MODEM_TTY" "$MODEM_RESET_TIMEOUT"; then
        log_message "ERROR: Modem not responding after reset"
        return 1
    fi

    log_message "Modem reset completed successfully."
    return 0
}

recover_connection() {
    log_message "WATCHDOG: Attempting to recover connection..."
    if reset_modem; then
        log_message "WATCHDOG: Modem reset successful, re-initializing..."
        return 0
#        if /jffs/scripts/fm350-connect.sh; then
#            return 0
#        fi
    fi
    log_message "WATCHDOG: Recovery failed, scheduling delayed reboot via guard..."
    /jffs/scripts/fm350-guard.sh now &
    return 1
}

acquire_lock() {
    local script_name="${1:-$SCRIPT_NAME}"
    local lock_file="/tmp/${script_name}.lock"
    local pid=""

    if [ -f "$lock_file" ]; then
        pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_message "Another instance of $script_name is already running (PID: $pid)"
            exit 0
        else
            log_message "Stale lock file found for $script_name (PID: $pid)"
            rm -f "$lock_file"
        fi
    fi

    echo "$$" > "$lock_file"
}

release_lock() {
    local script_name="${1:-$SCRIPT_NAME}"
    local lock_file="/tmp/${script_name}.lock"
    rm -f "$lock_file"
}

if ! echo "$WANS_DUALWAN" | grep -q "usb"; then
    log_message "USB modem not configured in Dual WAN"
    exit 0
fi

[ "$(nvram get usb_modem_act_type)" != "rndis" ] && exit 0

acquire_lock "$SCRIPT_NAME"
trap 'release_lock "$SCRIPT_NAME"' EXIT INT TERM