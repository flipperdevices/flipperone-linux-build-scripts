#!/bin/bash
exec /usr/bin/chromium \
    --ozone-platform=wayland \
    --force-dark-mode \
    --user-data-dir=/home/user/.config/chromium-standalone \
    --start-maximized \
    "https://google.com" \
    "http://speedtest.net"