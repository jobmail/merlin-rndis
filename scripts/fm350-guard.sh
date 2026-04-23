#!/bin/sh

REBOOT_COUNTER_FILE="/jffs/fm350.reboot"
MAX_ATTEMPTS=5

log_message() {
    local msg="$1"
    logger -t "FM350" "$msg"
    echo "$msg"
}

if ! nvram get wans_dualwan 2>/dev/null | grep -q "usb"; then
    log_message "USB modem is not configured in Dual WAN settings. Exiting."
    exit 1
fi

if [ -f "$REBOOT_COUNTER_FILE" ] && [ -s "$REBOOT_COUNTER_FILE" ]; then
    N=$(cat "$REBOOT_COUNTER_FILE")

    if ! echo "$N" | grep -qE '^[0-9]+$'; then
        N=0
    fi
else
    N=0
fi

if [ "$N" -gt "$MAX_ATTEMPTS" ]; then
    log_message "Reboot attempts limit ($MAX_ATTEMPTS) reached"
    exit 0
fi

N=$((N + 1))
echo "$N" > "$REBOOT_COUNTER_FILE"

WAIT_MINUTES=$((5 * N))
WAIT_SECONDS=$((WAIT_MINUTES * 60))

log_message "Watchdog initialization: attempt #$N, wait $WAIT_MINUTES min"

sleep $WAIT_SECONDS

if [ -f "$REBOOT_COUNTER_FILE" ]; then
    log_message "Watchdog initialization timeout $WAIT_MINUTES min expired"
    reboot
else
    log_message "Reboot flag disappeared"
fi
