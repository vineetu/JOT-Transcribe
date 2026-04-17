"""dmgbuild settings for the Jot DMG.

dmgbuild writes the .DS_Store directly — no AppleScript, no Finder
automation, no TCC prompt. Works in any shell context (CI, headless,
sandboxed) unlike create-dmg / hdiutil + osascript.

Values come from build-dmg.sh via `-D key=value` flags on the dmgbuild
command line. See the `defines` dict below.
"""

import os

# --- Inputs ------------------------------------------------------------------
application = defines["app"]
background = defines.get("background")
badge_icon = defines.get("badge_icon") or None

appname = os.path.basename(application)

# --- Format ------------------------------------------------------------------
format = "UDZO"
size = None

# --- Content -----------------------------------------------------------------
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]

# --- Window ------------------------------------------------------------------
# 640 x 400 interior. Matches Resources/dmg-background.png dimensions.
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
include_icon_view_settings = "auto"

# --- Icons -------------------------------------------------------------------
icon_size = 128
text_size = 13
# Y=210 matches the arrow in the background image.
icon_locations = {
    appname: (160, 210),
    "Applications": (480, 210),
}
