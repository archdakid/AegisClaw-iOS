#!/usr/bin/env bash
set -e

pkill -f 'socat.*usbmuxd' 2>/dev/null || true
pkill -x usbmuxd 2>/dev/null || true
mkdir -p /var/run
rm -f /var/run/usbmuxd

WRAPPER="/tmp/amds_bridge.sh"
echo '#!/usr/bin/env bash' > "$WRAPPER"
echo 'exec "/mnt/c/Program Files/nodejs/node.exe" "c:/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/scripts/amds-stdio-bridge.js"' >> "$WRAPPER"
chmod 777 "$WRAPPER"

nohup socat UNIX-LISTEN:/var/run/usbmuxd,fork,mode=666 EXEC:"$WRAPPER" </dev/null >/tmp/usbmuxd-socat.log 2>&1 &
sleep 2

/usr/bin/idevice_id -l || true
