#!/bin/sh

MODEM_TTY="/dev/ttyUSB4"
WAN_IF="eth3"
LOG_FILE="/tmp/fm350.log"
APN="internet"
GUARD_FILE="/jffs/fm350.reboot"

MODEM_READY_TIMEOUT=30
MODEM_RESET_TIMEOUT=60

log_message() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" | tee -a $LOG_FILE
    logger -t "FM350" "$msg"
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
        local first_line=$(echo "$response" | head -1 | tr -d '\r\t' | xargs)
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

send_at_silent() {
    send_at "$1" "$2" "1" > /dev/null 2>&1
    return $?
}

test_at_response_error() {
    echo "$1" | grep -qE "ERROR|CME ERROR"
    return $?
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
