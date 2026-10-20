#!/usr/bin/env bash
set -e

BRIDGE_JS="c:/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/scripts/amds-stdio-bridge.js"
NODE_EXE="/mnt/c/Program Files/nodejs/node.exe"

pkill -f 'socat.*usbmuxd' 2>/dev/null || true
pkill -x usbmuxd 2>/dev/null || true
mkdir -p /var/run
rm -f /var/run/usbmuxd

# Create a small wrapper in /tmp so socat EXEC doesn't have spaces in the command path
cat << 'EOF' > /tmp/run-amds-bridge.sh
#!/usr/bin/env bash
exec "/mnt/c/Program Files/nodejs/node.exe" "c:/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/scripts/amds-stdio-bridge.js"
EOF
chmod +x /tmp/run-amds-bridge.sh

nohup socat UNIX-LISTEN:/var/run/usbmuxd,fork,mode=666 EXEC:/tmp/run-amds-bridge.sh </dev/null >/tmp/usbmuxd-socat.log 2>&1 &
sleep 1
ls -la /var/run/usbmuxd
echo "Testing idevice_id -l:"
/usr/bin/idevice_id -l || true
echo "Testing xtool devices:"
sudo -u chadj /home/chadj/.local/bin/xtool devices --no-wait || true
cat /tmp/usbmuxd-socat.log || true
