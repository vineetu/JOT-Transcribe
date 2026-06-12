#!/bin/bash
# Guided capture for the 3 MacMenuBar screenshots (run on a Mac with Jot installed, macOS 14+).
# Saves to ~/Desktop as jot-shot-1/2/3.png plus a top-cropped *-crop.png of each.
set -e
OUT="$HOME/Desktop"

shot() {
  n="$1"; shift
  echo
  echo "── Shot $n ──────────────────────────────────────"
  echo "$@"
  echo
  read -r -p "Press Enter, then you have 4 seconds to set the scene… "
  sleep 4
  screencapture -x "$OUT/jot-shot-$n.png"
  # top strip crop (menu bar + context) — 1200px tall from the top edge
  W=$(sips -g pixelWidth "$OUT/jot-shot-$n.png" | awk '/pixelWidth/{print $2}')
  sips -s format png -c 1200 "$W" --cropOffset 0 0 "$OUT/jot-shot-$n.png" --out "$OUT/jot-shot-$n-crop.png" >/dev/null
  echo "✓ saved jot-shot-$n.png (+ -crop.png)"
}

echo "Before starting: hide clutter from the menu bar (⌘-drag icons off),"
echo "use a clean wallpaper, quit apps you don't want visible."

shot 1 "THE MENU: click Jot's menu bar icon so the dropdown menu is open."
shot 2 "THE PILL: start a recording (hotkey) over Notes — pill visible under the notch, menu bar in frame."
shot 3 "THE RESULT: finish dictating so the transcript just landed at the cursor."

echo
echo "Done. Use the -crop versions if MacMenuBar wants tighter menu-bar shots;"
echo "the full versions work for AlternativeTo and MacUpdate."
