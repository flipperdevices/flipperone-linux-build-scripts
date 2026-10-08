#!/bin/sh
# Run krdp on the real desktop when a display is connected, otherwise on a
# virtual screen, and restart it when a hotplug changes which one applies.
set -eu

display_connected() {
	for status in /sys/class/drm/card*-HDMI-A-*/status /sys/class/drm/card*-DP-*/status; do
		[ "$(cat "$status" 2>/dev/null)" = connected ] && return 0
	done
	return 1
}

case "${1:-}" in
start)
	shift
	if display_connected; then
		exec /usr/bin/krdpserver --plasma "$@"
	fi
	exec /usr/bin/krdpserver --plasma --virtual-monitor 1280x720@1 "$@"
	;;
hotplug)
	for pid in $(pgrep -x krdpserver || true); do
		if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- --virtual-monitor; then
			display_connected || continue
		else
			display_connected && continue
		fi
		uid=$(stat -c %u "/proc/$pid")
		runuser -u "$(id -nu "$uid")" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
			systemctl --user --no-block restart app-org.kde.krdpserver.service
	done
	;;
*)
	echo "usage: $0 start [krdpserver args] | hotplug" >&2
	exit 2
	;;
esac
