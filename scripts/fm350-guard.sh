#!/bin/sh

. /jffs/scripts/fm350-lib.sh

REBOOT_COUNTER_FILE="/jffs/fm350.reboot"
MAX_ATTEMPTS=5
DELAY_SECONDS_BEFORE_REBOOT=2

read_counter() {
    if [ -f "$REBOOT_COUNTER_FILE" ] && [ -s "$REBOOT_COUNTER_FILE" ]; then
        N=$(cat "$REBOOT_COUNTER_FILE")
        if ! echo "$N" | grep -qE '^[0-9]+$'; then
            N=0
        fi
    else
        N=0
    fi
    echo "$N"
}

increment_counter() {
    local current="$1"
    local next=$((current + 1))
    echo "$next" > "$REBOOT_COUNTER_FILE"
    log_message "GUARD: counter incremented to $next"
}

do_reboot() {
    log_message "GUARD: rebooting router now..."
    sleep $DELAY_SECONDS_BEFORE_REBOOT
    /sbin/reboot
    sleep 30
    echo b > /proc/sysrq-trigger 2>/dev/null
}

mode_delayed() {
    local N=$(read_counter)

    if [ "$N" -ge "$MAX_ATTEMPTS" ]; then
        log_message "GUARD: max attempts ($MAX_ATTEMPTS) reached"
        exit 0
    fi

    increment_counter "$N"
    N=$((N + 1))

    local wait_minutes=$((5 * N))
    local wait_seconds=$((wait_minutes * 60))

    log_message "GUARD: delayed mode, attempt #$N, waiting $wait_minutes min"

    sleep $wait_seconds

    if [ -f "$REBOOT_COUNTER_FILE" ]; then
        log_message "GUARD: timeout expired, rebooting..."
        do_reboot
    else
        log_message "GUARD: flag file disappeared, skipping reboot"
    fi
}

mode_now() {
    log_message "GUARD: immediate reboot requested"

    if ! nvram get wans_dualwan 2>/dev/null | grep -q "usb"; then
        log_message "GUARD: USB modem not configured in Dual WAN"
        exit 1
    fi

    local N=$(read_counter)
    if [ "$N" -ge "$MAX_ATTEMPTS" ]; then
        log_message "GUARD: max attempts ($MAX_ATTEMPTS) reached"
        exit 0
    fi

    increment_counter "$N"
    do_reboot
}

main() {
    case "${1:-delay}" in
        now)
            mode_now
            ;;
        delay|*)
            mode_delayed
            ;;
    esac
}

main "$@"
