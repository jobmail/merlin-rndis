#!/bin/sh
. /jffs/scripts/fm350-lib.sh

while true; do
    sleep 60
    if ! check_modem_health; then
        if ! recover_connection; then
            exit 1
        fi
    fi
done