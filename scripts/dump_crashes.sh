#!/usr/bin/env bash
set -e

bash /mnt/c/Users/chadj/OneDrive/Desktop/AegisClaw/AegisClaw-iOS-Repository/scripts/start-wsl-usbmuxd-bridge.sh

echo "Waiting for device..."
sleep 2

DEVICE_ID=$(/usr/bin/idevice_id -l | head -n 1)
echo "Detected Device: $DEVICE_ID"

mkdir -p /home/chadj/crashes_latest
echo "Extracting crash reports..."
idevicecrashreport -e -k /home/chadj/crashes_latest || true

echo "Extracted files:"
ls -la /home/chadj/crashes_latest
