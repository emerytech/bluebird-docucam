#!/bin/bash
cd "$(dirname "$0")/shots"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for f in shot*.html; do
  n="${f%.html}"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1280,800 --screenshot="$n.png" "file://$PWD/$f" 2>/dev/null
  echo "rendered $n.png ($(sips -g pixelWidth -g pixelHeight "$n.png" 2>/dev/null | grep -o '[0-9]*' | tr '\n' 'x' | sed 's/x$//'))"
done
