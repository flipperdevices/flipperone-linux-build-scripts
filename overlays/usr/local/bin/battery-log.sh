#!/bin/sh

STATEFILE=/run/charger_last_status
NEW="$POWER_SUPPLY_STATUS"

[ -z "$NEW" ] && exit 0

if [ -f "$STATEFILE" ]; then
    OLD=$(cat "$STATEFILE")
else
    OLD=""
fi

if [ "$NEW" != "$OLD" ]; then
    echo "$NEW" > "$STATEFILE"
    logger -t charger -p user.notice "$NEW"
fi
