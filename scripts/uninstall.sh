#!/bin/sh

set -e

SCRIPTS_DIR="/jffs/scripts"

EVENT_FILES="
dhcpc-event
wan-event
nat-start
init-start
services-start
firewall-start
"

PROJECT_SH_FILES="
fm350-connect.sh
fm350-firewall.sh
fm350-guard.sh
fm350-watchdog.sh
fm350-lib.sh
fm350-nat.sh
fm350-test.sh
set_nvram.sh
"

PROJECT_DATA_FILES="
init.nvram
"

log() {
    echo "[FM350 Uninstaller] $1"
}

remove_event_block() {
    local target="$1"
    local target_path="$SCRIPTS_DIR/$target"

    if [ ! -f "$target_path" ]; then
        log "File $target_path does not exist, skipping."
        return
    fi

    log "Processing $target_path"

    local tmp_file="/tmp/uninstall_$$.tmp"
    sed '/# >>> FM350 INSTALLER >>>/,/# <<< FM350 INSTALLER <<</d' "$target_path" > "$tmp_file"
    mv "$tmp_file" "$target_path"

    local remaining
    remaining=$(grep -v '^#!/bin/sh' "$target_path" | grep -v '^[[:space:]]*$' | wc -l)

    if [ "$remaining" -eq 0 ]; then
        log "  No other content, removing file $target_path"
        rm -f "$target_path"
    else
        log "  Other content present, keeping file $target_path"
    fi
}

remove_project_files() {
    log "Removing project .sh files..."
    for file in $PROJECT_SH_FILES; do
        if [ -f "$SCRIPTS_DIR/$file" ]; then
            rm -f "$SCRIPTS_DIR/$file"
            log "  Removed $file"
        else
            log "  $file not found, skipping"
        fi
    done

    log "Removing project data files..."
    for file in $PROJECT_DATA_FILES; do
        if [ -f "$SCRIPTS_DIR/$file" ]; then
            rm -f "$SCRIPTS_DIR/$file"
            log "  Removed $file"
        else
            log "  $file not found, skipping"
        fi
    done
}

main_uninstall() {
    log "Starting FM350 uninstallation..."

    for file in $EVENT_FILES; do
        remove_event_block "$file"
    done

    remove_project_files

    log "Uninstallation completed."
}

main_uninstall
