#!/bin/bash
# Chromium on the big screen. Kodi's Chromium favourite runs this with no arguments
# and gets the page below; the captive-portal hook passes the page it wants shown.
[ $# -gt 0 ] || set -- "https://duckduckgo.com"
exec /usr/bin/chromium \
    --ozone-platform=wayland \
    --password-store=basic \
    --force-dark-mode \
    --user-data-dir=/home/user/.config/chromium-standalone \
    --start-maximized \
    "$@"
