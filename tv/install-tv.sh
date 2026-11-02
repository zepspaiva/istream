#!/usr/bin/env bash
# Installs Free My TV on the TV at 192.168.1.34 (Barcelona settings are in config.properties).
set -e
cd "$(dirname "$0")"
TV=192.168.1.34
open_port() { nc -z -G 2 "$TV" "$1" >/dev/null 2>&1; }

echo "Looking at the TV at $TV..."
if open_port 5555; then KIND=android
elif open_port 3000 || open_port 3001 || open_port 9922; then KIND=lg
elif open_port 8001 || open_port 8002 || open_port 26101; then KIND=samsung
else
  echo "The TV at $TV didn't answer."
  echo "- Make sure it's on and on the same Wi-Fi as this Mac."
  echo "- Google TV / Android TV: Settings > System > About > tap 'Android TV OS build' 7 times,"
  echo "  then Settings > System > Developer options > USB debugging ON. Then run this again."
  echo "- If macOS asks to let Terminal find devices on your local network, click Allow."
  exit 1
fi
echo "Detected: $KIND"

if [ "$KIND" = lg ]; then
  echo "LG TV. On the TV: LG Content Store > Developer Mode > sign in > Dev Mode Status ON > Key Server ON."
  python3 webos/build.py
  python3 webos/install.py "$TV"     # asks for the passphrase shown on the TV
  exit 0
fi
if [ "$KIND" = samsung ]; then
  echo "Samsung TV. Easiest route: install TizenBrew Installer and choose Install from GitHub > simbasjungles/free-my-tv."
  echo "See the README's Samsung section. Come back to Claude if you want a custom build."
  exit 0
fi

# Google TV / Android TV
command -v brew >/dev/null || { echo "Homebrew is needed: https://brew.sh"; exit 1; }
command -v javac >/dev/null && javac -version 2>&1 | grep -qE ' (1[7-9]|[2-9][0-9])' || brew install --cask temurin
command -v adb >/dev/null || brew install --cask android-platform-tools
command -v sdkmanager >/dev/null || brew install --cask android-commandlinetools
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
[ -d "$ANDROID_HOME/build-tools/34.0.0" ] && [ -d "$ANDROID_HOME/platforms/android-34" ] || \
  yes | sdkmanager --sdk_root="$ANDROID_HOME" "build-tools;34.0.0" "platforms;android-34"

./build.sh
adb kill-server >/dev/null 2>&1 || true
echo ">>> On the TV: accept 'Allow USB debugging?' and tick 'Always allow'."
adb connect "$TV:5555"
for i in $(seq 1 30); do adb -s "$TV:5555" get-state 2>/dev/null | grep -q device && break; sleep 2; done
echo ">>> If the install seems stuck, the TV is asking: choose More details > Install anyway."
adb -s "$TV:5555" install -r FreeMyTV.apk
if adb -s "$TV:5555" shell getprop ro.product.brand | grep -qi tcl; then
  adb -s "$TV:5555" shell "appops set io.freemytv AUTO_START allow || appops set io.freemytv APP_AUTO_START allow" || true
fi
adb disconnect "$TV:5555"
echo
echo "Done! On the TV: open Free My TV > Home Screen > Free My TV, and accept the debugging prompt (Always allow)."
echo "To undo anytime: Free My TV > Home Screen > Original."
