#!/bin/sh

set -e

SCRIPTS_DIR="/jffs/scripts"
INSTALL_DIR="$(dirname "$0")"

EVENT_FILES="
dhcpc-event:dhcpc-event.txt
wan-event:wan-event.txt
nat-start:nat-start.txt
init-start:init-start.txt
services-start:services-start.txt
firewall-start:firewall-start.txt
"

PROJECT_SH_FILES="
fm350-connect.sh
fm350-firewall.sh
fm350-guard.sh
fm350-lib.sh
fm350-nat.sh
set_nvram.sh
"

PROJECT_DATA_FILES="
init.nvram
"

PROJECT_AUTHOR="Refresh"
PROJECT_GITHUB="https://github.com/jobmail/merlin-rndis"
PROJECT_LICENSE="MIT"
INSTALL_DATE=$(date "+%Y-%m-%d %H:%M:%S")

log() {
    echo "[FM350 Installer] $1"
}

generate_header() {
    cat << EOF
#!/bin/sh
#
# ============================================
#  FM350 Connection Script Collection
# ============================================
#  Author:      $PROJECT_AUTHOR
#  Version:	1.0
#  Date:	$INSTALL_DATE
#  GitHub:      $PROJECT_GITHUB
#  License:     $PROJECT_LICENSE
#
#  Permission is hereby granted, free of charge, to any person obtaining
#  a copy of this software and associated documentation files (the "Software"),
#  to deal in the Software without restriction, including without limitation
#  the rights to use, copy, modify, merge, publish, distribute, sublicense,
#  and/or sell copies of the Software, and to permit persons to whom the
#  Software is furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included
#  in all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
#  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
#  THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
#  OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
#  ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#  OTHER DEALINGS IN THE SOFTWARE.
# ============================================
#
EOF
}

copy_sh_with_header() {
    local src="$1"
    local dst="$2"
    local tmp_file="/tmp/copy_sh_$$.tmp"

    {
        generate_header
        awk 'NR==1 && /^#!/ {next} {print}' "$src"
    } > "$tmp_file"

    mv "$tmp_file" "$dst"
    chmod +x "$dst"
    log "  Copied and updated header for $(basename "$dst")"
}

install_event_file() {
    local target="$1"
    local source="$2"
    local target_path="$SCRIPTS_DIR/$target"
    local source_path="$INSTALL_DIR/$source"

    if [ ! -f "$source_path" ]; then
        log "WARNING: Source file $source_path not found, skipping $target"
        return
    fi

    local content
    content=$(awk 'NR==1 && /^#!/ {next} {print}' "$source_path")

    local marked_content="# >>> FM350 INSTALLER >>>
$content
# <<< FM350 INSTALLER <<<"

    if [ ! -f "$target_path" ]; then
        log "Creating $target_path"
        echo "#!/bin/sh" > "$target_path"
        echo "" >> "$target_path"
        echo "$marked_content" >> "$target_path"
        chmod +x "$target_path"
    else
        log "Updating $target_path"
        if grep -q "# >>> FM350 INSTALLER >>>" "$target_path"; then
            sed -i '/# >>> FM350 INSTALLER >>>/,/# <<< FM350 INSTALLER <<</d' "$target_path"
        fi
        echo "" >> "$target_path"
        echo "$marked_content" >> "$target_path"
        chmod +x "$target_path"
    fi
}

main_install() {
    log "Starting FM350 installation..."

    mkdir -p "$SCRIPTS_DIR"

    old_IFS="$IFS"
    IFS='
'
    for pair in $EVENT_FILES; do
        target="${pair%%:*}"
        source="${pair##*:}"
        install_event_file "$target" "$source"
    done
    IFS="$old_IFS"

    log "Copying project .sh files with header..."
    for file in $PROJECT_SH_FILES; do
        src="$INSTALL_DIR/$file"
        if [ -f "$src" ]; then
            dst="$SCRIPTS_DIR/$file"
            copy_sh_with_header "$src" "$dst"
        else
            log "  WARNING: $file not found in $INSTALL_DIR"
        fi
    done

    log "Copying project data files..."
    for file in $PROJECT_DATA_FILES; do
        if [ -f "$INSTALL_DIR/$file" ]; then
            cp -f "$INSTALL_DIR/$file" "$SCRIPTS_DIR/$file"
            log "  Copied $file"
        else
            log "  WARNING: $file not found in $INSTALL_DIR"
        fi
    done

    log "Enabling JFFS custom scripts..."
    nvram set jffs2_scripts=1
    nvram commit
    log "JFFS scripts enabled."

    log "Installation completed successfully."
    log "Please reboot the router for all changes to take effect."
}

main_install
