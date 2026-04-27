#!/bin/sh

. /jffs/scripts/fm350-lib.sh

trap '' SIGPIPE
trap '' SIGHUP

if [ "$1" = "check" ]; then
    log_message "WATCHDOG: Immediate health check requested"
    if ! check_modem_health; then
        log_message "WATCHDOG: Health check failed, attempting recovery..."
        recover_connection
    else
        log_message "WATCHDOG: Health check OK"
    fi
fi

while true; do
    sleep 15
    if [ -f "/tmp/fm350-connect.sh.lock" ]; then
        pid=$(cat /tmp/fm350-connect.sh.lock 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_message "WATCHDOG: fm350-connect.sh is running (PID: $pid), skipping health check"
            continue
        else
            log_message "WATCHDOG: Stale lock file found, removing"
            rm -f /tmp/fm350-connect.sh.lock
        fi
    fi
    if ! check_modem_health; then
        recover_connection || exit 1
    fi
done