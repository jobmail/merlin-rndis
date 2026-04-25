#!/bin/sh

. /jffs/scripts/fm350-lib.sh

echo "=========================================="
echo "FM350 AT Port Test Script"
echo "=========================================="

if [ ! -c "$MODEM_TTY" ]; then
    echo "ERROR: $MODEM_TTY not found or not a character device."
    exit 1
fi

stty -F "$MODEM_TTY" raw -icanon -echo min 0 time 5 2>/dev/null
echo "Serial port configured."

print_response() {
    local description="$1"
    local response="$2"
    echo ""
    echo "--- $description ---"
    echo "$response" | head -20 | tr -d '\r\t' | tr '\n' ' '
    echo ""
    echo "--- end ---"
}

echo ""
echo ">>> Test 1: AT (basic communication)"
response=$(send_at "AT" 5)
echo "Return code: $?"
print_response "AT" "$response"

echo ""
echo ">>> Test 2: AT+CGMI (manufacturer)"
response=$(send_at "AT+CGMI" 5)
echo "Return code: $?"
print_response "Manufacturer" "$response"

echo ""
echo ">>> Test 3: AT+GMM (model)"
response=$(send_at "AT+GMM" 5)
echo "Return code: $?"
print_response "Model" "$response"

echo ""
echo ">>> Test 4: AT+GMR (firmware)"
response=$(send_at "AT+GMR" 5)
echo "Return code: $?"
print_response "Firmware" "$response"

echo ""
echo ">>> Test 5: AT+CGSN (IMEI)"
response=$(send_at "AT+CGSN" 5)
echo "Return code: $?"
print_response "IMEI" "$response"

echo ""
echo ">>> Test 6: AT+CPIN? (SIM status)"
response=$(send_at "AT+CPIN?" 5)
echo "Return code: $?"
print_response "SIM Status" "$response"

echo ""
echo ">>> Test 7: AT+CSQ (signal quality)"
response=$(send_at "AT+CSQ" 5)
echo "Return code: $?"
print_response "Signal Quality" "$response"

echo ""
echo ">>> Test 8: send_at_silent (no log)"
response=$(send_at_silent "AT+CGMI" 5 1)
echo "Return code: $?"
print_response "CGMI (echo off)" "$response"

echo ""
echo ">>> Test 9: BADD"
response=$(send_at "BADD" 5 1)
echo "Return code: $?"
print_response "BADD" "$response"

echo ""
echo "=========================================="
echo "Testing completed."
echo "=========================================="
