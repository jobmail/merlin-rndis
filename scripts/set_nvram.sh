#!/bin/sh

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "Usage: $0 <file> [commit_flag]"
    echo "  commit_flag: 1 to commit changes (optional)"
    exit 1
fi

INPUT_FILE="$1"
COMMIT_FLAG="${2:-0}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' not found."
    exit 1
fi

if [ ! -r "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' is not readable."
    exit 1
fi

total=0
success=0
failed=0

echo "Processing NVRAM settings from '$INPUT_FILE'..."
echo "=========================================="

while IFS= read -r line || [ -n "$line" ]; do
    trimmed_line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    if [ -z "$trimmed_line" ] || echo "$trimmed_line" | grep -q '^#'; then
        continue
    fi
    
    total=$((total + 1))
    
    echo -n "Setting: $trimmed_line ... "
    
    if eval nvram set "$trimmed_line" 2>/dev/null; then
        echo "OK"
        success=$((success + 1))
    else
        echo "FAILED"
        failed=$((failed + 1))
    fi
done < "$INPUT_FILE"

echo "=========================================="
echo "Total: $total, Success: $success, Failed: $failed"

if [ "$COMMIT_FLAG" = "1" ]; then
    if [ $success -gt 0 ]; then
        echo -n "Committing changes to NVRAM... "
        if nvram commit 2>/dev/null; then
            echo "OK"
        else
            echo "FAILED"
        fi
    else
        echo "No successful settings to commit."
    fi
else
    echo "Changes NOT committed (commit_flag is not 1)."
fi

exit 0
