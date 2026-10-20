#!/usr/bin/env bash
set -e

IPA_WSL_PATH="${1:-/mnt/c/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/AegisClaw-unsigned.ipa}"

# 1. Start the usbmuxd bridge as root
bash /mnt/c/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/scripts/start-wsl-usbmuxd-bridge.sh

export XTL_DISABLE_TLS_VALIDATION=1

# 2. Check xtool auth status as chadj
AUTH_OUT=$(sudo -u chadj env XTL_DISABLE_TLS_VALIDATION=1 /home/chadj/.local/bin/xtool auth status 2>&1 || true)
echo "xtool auth status: $AUTH_OUT"

if echo "$AUTH_OUT" | grep -qi "Logged out"; then
  echo ""
  echo "=== Apple ID Login Required for xtool ==="
  if ! sudo -u chadj env XTL_DISABLE_TLS_VALIDATION=1 /home/chadj/.local/bin/xtool auth login; then
    echo "[!] xtool auth login failed. Please review the output above."
    exit 1
  fi
fi

# 3. Sign and install the IPA onto the USB-connected iPhone
echo ""
echo "=== Signing and Installing $IPA_WSL_PATH onto iPhone ==="
sudo -u chadj env XTL_DISABLE_TLS_VALIDATION=1 XTL_DEV_LOG='.*' /home/chadj/.local/bin/xtool install --usb "$IPA_WSL_PATH"
