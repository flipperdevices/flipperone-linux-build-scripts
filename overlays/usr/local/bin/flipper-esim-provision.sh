#!/usr/bin/env bash
# flipper-esim-provision.sh — install and enable a Flipper eSIM profile on the
# Flipper One built-in eUICC through the M.2 cellular modem (Quectel, QMI mode).
#
# What it does, step by step:
#   1. checks tools (lpac, qmicli, jq, gpioset), installs missing ones if allowed
#   2. drives the SIM switch to the eSIM side (GPIO1_C0 = 0)
#   3. stops ModemManager so lpac/qmicli own the modem, re-initialises the SIM
#   4. reads the eUICC: EID, platform, free memory, installed profiles
#   5. downloads the profile from the SM-DP+ (matching ID or activation code)
#   6. enables it, sends the notifications to the SM-DP+, re-reads the SIM
#   7. verifies the modem now sees the new ICCID, restarts ModemManager
#   8. prints a summary and appends a line to the provisioning CSV log
#
# Usage (as root on the device):
#   sudo ./flipper-esim-provision.sh -m <matching id> [-s <smdp>] [-c <confirmation code>]
#   sudo ./flipper-esim-provision.sh -a 'LPA:1$smdp.example.com$MATCHING-ID'
#   sudo ./flipper-esim-provision.sh -h
#
# Per-run values come from the arguments. Line-wide defaults (SM-DP+ address,
# modem device, GPIO, log paths) live in the CONFIG block below and can also be
# overridden from the environment, e.g.  SMDP_ADDRESS=rsp.example.com sudo -E ./flipper-esim-provision.sh -m X

# ============================== CONFIG ======================================

# --- Profile defaults (per-run values come from the command line) ------------
SMDP_ADDRESS="${SMDP_ADDRESS:-smdp.example.com}"      # Flipper SM-DP+, used when -s / -a are not given
PROFILE_NICKNAME="${PROFILE_NICKNAME:-Flipper eSIM}"  # stored on the eUICC, -n overrides, empty = none
ENABLE_AFTER_DOWNLOAD="${ENABLE_AFTER_DOWNLOAD:-1}"   # 1 = enable the new profile, -E disables
IMEI="${IMEI:-}"                                       # IMEI to report to the SM-DP+, empty = lpac default
MATCHING_ID=""; ACTIVATION_CODE=""; CONFIRMATION_CODE=""   # set by -m / -a / -c

# --- Modem ---------------------------------------------------------------------
QMI_DEVICE="${QMI_DEVICE:-/dev/cdc-wdm0}"
UIM_SLOT="${UIM_SLOT:-1}"                              # M.2 exposes UIM1 only
STOP_MODEMMANAGER="${STOP_MODEMMANAGER:-1}"           # 1 = stop MM while working, restart after
SIM_READY_TIMEOUT="${SIM_READY_TIMEOUT:-45}"          # seconds to wait for the eUICC to answer
CHECK_REGISTRATION="${CHECK_REGISTRATION:-0}"         # 1 = after MM restart wait for network registration
REGISTRATION_TIMEOUT="${REGISTRATION_TIMEOUT:-90}"
MODEM_REAPPEAR_TIMEOUT="${MODEM_REAPPEAR_TIMEOUT:-120}"     # RG255C-GL needs ~60s to come back after a reset

# --- SIM switch (GPIO1_C0: 1 = physical nano-SIM, 0 = eSIM) --------------------
SWITCH_TO_ESIM="${SWITCH_TO_ESIM:-1}"                  # 0 = assume the switch is already on eSIM
SIM_SEL_MMIO="${SIM_SEL_MMIO:-2ae10000}"              # GPIO1 bank address on RK3576
SIM_SEL_LINE="${SIM_SEL_LINE:-16}"                     # C0 = line 16 of the bank
RESTORE_PHYSICAL_SIM_AT_END="${RESTORE_PHYSICAL_SIM_AT_END:-0}"

# --- Tooling -------------------------------------------------------------------
INSTALL_DEPS="${INSTALL_DEPS:-1}"                      # apt-get install missing packages
LPAC_DEB_URL="${LPAC_DEB_URL:-https://github.com/estkme-group/lpac/releases/download/v2.3.0/lpac_2.3.0_arm64.deb}"

# --- Logging -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/var/log/flipper-esim}"
CSV_LOG="${CSV_LOG:-$LOG_DIR/provisioning.csv}"
VERBOSE="${VERBOSE:-0}"                                # 1 = show lpac progress lines

# ============================ END OF CONFIG =================================

set -uo pipefail

usage() {
    cat <<EOF
Usage: sudo $0 -m <matching id> [options]
       sudo $0 -a '<activation code>' [options]

Profile:
  -m ID        matching ID on the SM-DP+
  -s HOST      SM-DP+ address (default: $SMDP_ADDRESS)
  -a CODE      activation code 'LPA:1\$host\$matching-id' (overrides -s/-m)
  -c CODE      confirmation code, if the SM-DP+ requires one
  -i IMEI      IMEI to report to the SM-DP+
  -n NAME      nickname stored on the eUICC (default: "$PROFILE_NICKNAME", "" = none)
  -E           download only, do not enable the profile
Device:
  -d DEV       QMI control device (default: $QMI_DEVICE)
  -S           do not touch the SIM switch (assume it is already on eSIM)
  -M           do not stop ModemManager while working
  -R           after ModemManager restarts, wait for network registration
Output:
  -v           show lpac progress lines
  -h           this help

Everything else (GPIO bank/line, timeouts, log paths) is in the CONFIG block at
the top of the script and can be overridden from the environment.
EOF
}

while getopts ':m:s:a:c:i:n:Ed:SMRvh' opt; do
    case "$opt" in
        m) MATCHING_ID=$OPTARG ;;
        s) SMDP_ADDRESS=$OPTARG ;;
        a) ACTIVATION_CODE=$OPTARG ;;
        c) CONFIRMATION_CODE=$OPTARG ;;
        i) IMEI=$OPTARG ;;
        n) PROFILE_NICKNAME=$OPTARG ;;
        E) ENABLE_AFTER_DOWNLOAD=0 ;;
        d) QMI_DEVICE=$OPTARG ;;
        S) SWITCH_TO_ESIM=0 ;;
        M) STOP_MODEMMANAGER=0 ;;
        R) CHECK_REGISTRATION=1 ;;
        v) VERBOSE=1 ;;
        h) usage; exit 0 ;;
        :) echo "option -$OPTARG needs a value" >&2; usage >&2; exit 2 ;;
        \?) echo "unknown option -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || { echo "unexpected argument: $1" >&2; usage >&2; exit 2; }
if [ -z "$MATCHING_ID" ] && [ -z "$ACTIVATION_CODE" ]; then
    echo "need -m <matching id> or -a <activation code>" >&2; usage >&2; exit 2
fi

# ------------------------------- output ---------------------------------------
if [ -t 1 ]; then
    C_HDR=$'\e[1;36m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_HDR=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
ts()   { date '+%H:%M:%S'; }
step() { STEP_N=$((STEP_N + 1)); printf '\n%s[%s] Step %d: %s%s\n' "$C_HDR" "$(ts)" "$STEP_N" "$*" "$C_RST"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[OK] %s%s\n' "$C_OK" "$*" "$C_RST"; }
warn() { printf '  %s[!!] %s%s\n' "$C_WARN" "$*" "$C_RST"; }
kv()   { printf '  %-22s %s\n' "$1" "$2"; }
die()  { printf '\n%s[FAIL] %s%s\n' "$C_ERR" "$*" "$C_RST"; RESULT="FAILED: $*"; finish 1; }
STEP_N=0
RESULT="not started"
START_TS=$(date '+%Y-%m-%dT%H:%M:%S%z')
HOSTNAME_S=$(hostname)

# state used by the summary / cleanup
EID=""; PLATFORM=""; NEW_ICCID=""; ENABLED_ICCID=""; MM_WAS_ACTIVE=0; GPIOSET_STARTED=0; SIM_CHIP=""

# ------------------------------- cleanup --------------------------------------
finish() {
    local rc=${1:-0}
    trap - EXIT
    if [ "$STOP_MODEMMANAGER" = 1 ] && [ "$MM_WAS_ACTIVE" = 1 ]; then
        systemctl start ModemManager 2>/dev/null && info "ModemManager started again"
    fi
    if [ "$RESTORE_PHYSICAL_SIM_AT_END" = 1 ] && [ -n "$SIM_CHIP" ]; then
        pkill -x gpioset 2>/dev/null
        gpioset -c "$SIM_CHIP" -z "$SIM_SEL_LINE=1" 2>/dev/null && info "SIM switch returned to the physical SIM"
    fi
    print_summary "$rc"
    write_csv "$rc"
    exit "$rc"
}
trap 'die "interrupted"' INT TERM
trap 'finish $?' EXIT

print_summary() {
    printf '\n%s================ SUMMARY ================%s\n' "$C_HDR" "$C_RST"
    kv "Device"           "$HOSTNAME_S"
    kv "Started"          "$START_TS"
    kv "EID"              "${EID:--}"
    kv "eUICC platform"   "${PLATFORM:--}"
    kv "SM-DP+"           "${SMDP_ADDRESS:--}"
    kv "Matching ID"      "${MATCHING_ID:--}"
    kv "New profile ICCID" "${NEW_ICCID:--}"
    kv "Enabled ICCID"    "${ENABLED_ICCID:--}"
    if [ "${1:-0}" = 0 ]; then
        printf '  %-22s %s%s%s\n' "Result" "$C_OK" "$RESULT" "$C_RST"
    else
        printf '  %-22s %s%s%s\n' "Result" "$C_ERR" "$RESULT" "$C_RST"
    fi
    [ -n "${LOG_FILE:-}" ] && kv "Log" "$LOG_FILE"
}

write_csv() {
    mkdir -p "$(dirname "$CSV_LOG")" 2>/dev/null || return 0
    [ -s "$CSV_LOG" ] || echo "timestamp,device,eid,platform,smdp,matching_id,new_iccid,enabled_iccid,result" > "$CSV_LOG"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
        "$START_TS" "$HOSTNAME_S" "$EID" "$PLATFORM" "$SMDP_ADDRESS" "$MATCHING_ID" \
        "$NEW_ICCID" "$ENABLED_ICCID" "${RESULT//\"/\'}" >> "$CSV_LOG"
}

# ------------------------------- helpers --------------------------------------
need_root() { [ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }; }

have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
    [ "$INSTALL_DEPS" = 1 ] || die "missing packages: $* (set INSTALL_DEPS=1 or install by hand)"
    info "installing: $*"
    apt-get update -qq >/dev/null 2>&1 || warn "apt-get update failed, trying install anyway"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || die "apt-get install $* failed"
}

install_lpac() {
    [ "$INSTALL_DEPS" = 1 ] || die "lpac is not installed"
    info "lpac not found, installing from $LPAC_DEB_URL"
    local deb=/tmp/lpac_arm64.deb
    curl -fsSL "$LPAC_DEB_URL" -o "$deb" || die "cannot download lpac .deb"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$deb" >/dev/null 2>&1 || die "lpac .deb install failed"
    rm -f "$deb"
}

# qmicli against the modem. ModemManager is stopped while we work, so no proxy.
qmi() { qmicli -d "$QMI_DEVICE" "$@" 2>&1; }

# lpac wrapper: runs lpac, shows progress if VERBOSE, returns the final "lpa"
# JSON payload on stdout, fails (non-zero) if lpac reported code != 0.
export LPAC_APDU=qmi
export LPAC_APDU_QMI_DEVICE="$QMI_DEVICE"
export LPAC_APDU_QMI_UIM_SLOT="$UIM_SLOT"
lpa() {
    local out final code msg
    out=$(lpac "$@" 2>/tmp/lpac.stderr) ; local rc=$?
    if [ "$VERBOSE" = 1 ]; then
        printf '%s\n' "$out" | jq -r 'select(.type=="progress") | "    · \(.payload.message)"' 2>/dev/null
    fi
    final=$(printf '%s\n' "$out" | jq -c 'select(.type=="lpa")' 2>/dev/null | tail -n1)
    if [ -z "$final" ]; then
        printf '%s\n' "$out" >&2; cat /tmp/lpac.stderr >&2
        return 1
    fi
    code=$(printf '%s' "$final" | jq -r '.payload.code')
    msg=$(printf '%s' "$final" | jq -r '.payload.message')
    LPA_LAST_MSG="$msg"
    LPA_LAST_DATA=$(printf '%s' "$final" | jq -r '.payload.data // empty')
    printf '%s' "$final" | jq -c '.payload'
    [ "$code" = 0 ] && [ "$rc" = 0 ]
}

card_state() {
    qmi --uim-get-card-status | sed -n "s/.*Card state: '\([^']*\)'.*/\1/p" | head -n1
}

wait_for_sim() {
    local deadline=$((SECONDS + SIM_READY_TIMEOUT)) st=""
    while [ $SECONDS -lt $deadline ]; do
        [ -e "$QMI_DEVICE" ] || { sleep 1; continue; }
        st=$(card_state)
        case "$st" in
            present) echo present; return 0 ;;
            "") ;;
            *) [ "$VERBOSE" = 1 ] && info "card state: $st" ;;
        esac
        sleep 2
    done
    echo "${st:-no answer}"
    return 1
}

sim_power_cycle() {
    qmi --uim-sim-power-off="$UIM_SLOT" >/dev/null; sleep 1
    qmi --uim-sim-power-on="$UIM_SLOT" >/dev/null
}

profile_table() {
    # prints installed profiles, one per line
    local list
    list=$(lpa profile list) || return 1
    printf '%s' "$list" | jq -r '
        .data[]? | "  \(.iccid)  \(.profileState | ascii_upcase | .[0:8] | . + " " * (8 - length))  \(.serviceProviderName // "-")  \(.profileName // "-")  \(.profileNickname // "")"'
}

# ------------------------------- run ------------------------------------------
need_root
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="$LOG_DIR/$(date '+%Y%m%d-%H%M%S')-$HOSTNAME_S.log"
exec > >(tee -a "$LOG_FILE") 2>&1

printf '%sFlipper One eSIM provisioning%s  %s  host=%s\n' "$C_HDR" "$C_RST" "$START_TS" "$HOSTNAME_S"

# ---- 1. tools ---------------------------------------------------------------
step "Checking tools"
have jq      || apt_install jq
have qmicli  || apt_install libqmi-utils
have gpioset || apt_install gpiod
have curl    || apt_install curl
have lpac    || install_lpac
kv "lpac"    "$(dpkg-query -W -f='${Version}' lpac 2>/dev/null || echo "present ($(command -v lpac))")"
kv "qmicli"  "$(qmicli --version 2>/dev/null | head -n1)"
[ -e "$QMI_DEVICE" ] || die "modem control device $QMI_DEVICE not found (is the M.2 modem in QMI mode?)"
ok "tools ready"

# ---- 2. profile parameters --------------------------------------------------
step "Profile parameters"
if [ -n "$ACTIVATION_CODE" ]; then
    # LPA:1$smdp$matching[$oid[$confcode-flag]]
    IFS='$' read -r _ SMDP_ADDRESS MATCHING_ID _ <<<"$ACTIVATION_CODE"
    kv "Activation code" "$ACTIVATION_CODE"
fi
[ -n "$SMDP_ADDRESS" ] && [ "$SMDP_ADDRESS" != "smdp.example.com" ] || die "SMDP_ADDRESS is not set"
[ -n "$MATCHING_ID" ] || die "MATCHING_ID is not set (or ACTIVATION_CODE)"
kv "SM-DP+"            "$SMDP_ADDRESS"
kv "Matching ID"       "$MATCHING_ID"
kv "Confirmation code" "${CONFIRMATION_CODE:+(set)}${CONFIRMATION_CODE:-none}"
kv "IMEI"              "${IMEI:-default}"
kv "Enable after"      "$ENABLE_AFTER_DOWNLOAD"

# ---- 3. SIM switch ----------------------------------------------------------
step "SIM switch to eSIM (GPIO1_C0 = 0)"
if [ "$SWITCH_TO_ESIM" = 1 ]; then
    chipdir=$(ls -d /sys/devices/platform/pinctrl/"$SIM_SEL_MMIO".gpio 2>/dev/null | head -n1)
    [ -n "$chipdir" ] || die "GPIO bank $SIM_SEL_MMIO not found in sysfs"
    SIM_CHIP=$(ls "$chipdir" | grep '^gpiochip' | head -n1)
    kv "gpiochip" "$SIM_CHIP (bank @$SIM_SEL_MMIO, line $SIM_SEL_LINE)"
    line_info=$(gpioinfo -c "$SIM_CHIP" 2>/dev/null | grep -E "^\s*line\s+$SIM_SEL_LINE:" || true)
    if printf '%s' "$line_info" | grep -qi 'physical SIM'; then
        die "the kernel holds this line (sim-sel-hog 'Force physical SIM'); eSIM cannot be selected without a device-tree change"
    fi
    pkill -x gpioset 2>/dev/null && sleep 0.3
    gpioset -c "$SIM_CHIP" -z "$SIM_SEL_LINE=0" || die "gpioset failed on $SIM_CHIP line $SIM_SEL_LINE"
    GPIOSET_STARTED=1
    ok "switch driven to eSIM"
else
    warn "SWITCH_TO_ESIM=0, assuming the switch is already on the eSIM side"
fi

# ---- 4. take the modem ------------------------------------------------------
step "Preparing the modem"
if [ "$STOP_MODEMMANAGER" = 1 ]; then
    systemctl is-active --quiet ModemManager && MM_WAS_ACTIVE=1
    systemctl stop ModemManager 2>/dev/null || true
    pkill -x qmi-proxy 2>/dev/null || true
    info "ModemManager stopped for the duration of provisioning"
fi
sim_power_cycle
info "SIM interface power-cycled, waiting for the eUICC (up to ${SIM_READY_TIMEOUT}s)"
st=$(wait_for_sim) || die "eUICC did not answer: card state '$st' (no-atr-received = hardware path to the chip is broken or the switch is not on eSIM)"
slot=$(qmi --uim-get-slot-status)
is_euicc=$(printf '%s' "$slot" | sed -n "s/.*Is eUICC: *\(\w*\).*/\1/p" | head -n1)
cur_iccid=$(printf '%s' "$slot" | sed -n "s/.*ICCID: *\([0-9A-Fa-f]*\).*/\1/p" | head -n1)
kv "Card state" "present"
kv "Is eUICC"   "${is_euicc:-unknown}"
kv "Active ICCID" "${cur_iccid:--}"
[ "$is_euicc" = yes ] || die "the card on slot $UIM_SLOT is not an eUICC (a physical SIM is connected?)"
ok "eUICC is answering"

# ---- 5. chip info -----------------------------------------------------------
step "Reading the eUICC"
chip=$(lpa chip info) || die "lpac chip info failed: $LPA_LAST_MSG $LPA_LAST_DATA"
EID=$(printf '%s' "$chip" | jq -r '.data.eidValue')
PLATFORM=$(printf '%s' "$chip" | jq -r '.data.EUICCInfo2.certificationDataObject.platformLabel // "" | if . == "" then "-" else . end')
SAS=$(printf '%s' "$chip" | jq -r '.data.EUICCInfo2.sasAcreditationNumber // "" | gsub("\\s+$";"") | if . == "" then "-" else . end')
kv "EID"            "$EID"
kv "Platform"       "$PLATFORM"
kv "SAS accreditation" "$SAS"
kv "eUICC FW"       "$(printf '%s' "$chip" | jq -r '.data.EUICCInfo2.euiccFirmwareVer // "-"')"
kv "SGP.22 version" "$(printf '%s' "$chip" | jq -r '.data.EUICCInfo2.svn // "-"')"
kv "Free NVM"       "$(printf '%s' "$chip" | jq -r '(.data.EUICCInfo2.extCardResource.freeNonVolatileMemory // 0) / 1024 | floor') KiB"
kv "Default SM-DP+" "$(printf '%s' "$chip" | jq -r '.data.EuiccConfiguredAddresses.defaultDpAddress // "none"')"
info "Installed profiles before:"
before_list=$(lpa profile list) || die "lpac profile list failed: $LPA_LAST_MSG"
before_iccids=$(printf '%s' "$before_list" | jq -r '.data[]?.iccid')
if [ -n "$before_iccids" ]; then profile_table; else info "  (none listed)"; fi
if [ -n "$cur_iccid" ] && ! printf '%s\n' "$before_iccids" | grep -qx "$cur_iccid"; then
    warn "the modem sees ICCID $cur_iccid on the card, but the eUICC does not list it as a profile (hidden factory/test profile?)"
fi

# ---- 6. download ------------------------------------------------------------
step "Downloading the profile from $SMDP_ADDRESS"
dl_args=(-s "$SMDP_ADDRESS" -m "$MATCHING_ID")
[ -n "$CONFIRMATION_CODE" ] && dl_args+=(-c "$CONFIRMATION_CODE")
[ -n "$IMEI" ] && dl_args+=(-i "$IMEI")
info "lpac profile download ${dl_args[*]//$CONFIRMATION_CODE/****}"
if ! lpa profile download "${dl_args[@]}" >/dev/null; then
    case "$LPA_LAST_MSG" in
        es10b_load_bound_profile_package|es10b_prepare_download)
            hint="the eUICC rejected the profile package while installing it: profile/eUICC incompatibility (PE type, applets, package format) — report EID, matching ID and this error to the profile provider; run 'lpac notification process -a -r' so the SM-DP+ learns about the failure" ;;
        es9p_initiate_authentication|es9p_authenticate_client)
            hint="the SM-DP+ refused this eUICC or matching ID: wrong/consumed matching ID, EID not allowed for this order, or the eUICC certificate is not accepted by this SM-DP+" ;;
        es9p_get_bound_profile_package)
            hint="the SM-DP+ did not hand out the package: wrong confirmation code, or the order is not in a downloadable state" ;;
        *http*|*curl*|*connect*|*resolve*)
            hint="network problem: the device needs internet (Wi-Fi/Ethernet) to reach $SMDP_ADDRESS" ;;
        *) hint="check internet on the device, the matching ID, and whether the profile was already consumed" ;;
    esac
    die "download failed at '$LPA_LAST_MSG': ${LPA_LAST_DATA:-no details} ($hint)"
fi
after_list=$(lpa profile list) || die "lpac profile list failed after download"
NEW_ICCID=$(comm -13 <(printf '%s\n' "$before_iccids" | sort) <(printf '%s' "$after_list" | jq -r '.data[]?.iccid' | sort) | head -n1)
[ -n "$NEW_ICCID" ] || die "download reported success but no new profile appeared on the eUICC"
kv "New ICCID"    "$NEW_ICCID"
kv "Provider"     "$(printf '%s' "$after_list" | jq -r --arg i "$NEW_ICCID" '.data[] | select(.iccid==$i) | .serviceProviderName // "-"')"
kv "Profile name" "$(printf '%s' "$after_list" | jq -r --arg i "$NEW_ICCID" '.data[] | select(.iccid==$i) | .profileName // "-"')"
ok "profile installed"
if [ -n "$PROFILE_NICKNAME" ]; then
    lpa profile nickname "$NEW_ICCID" "$PROFILE_NICKNAME" >/dev/null && kv "Nickname" "$PROFILE_NICKNAME" || warn "could not set nickname: $LPA_LAST_MSG"
fi

# ---- 7. enable --------------------------------------------------------------
if [ "$ENABLE_AFTER_DOWNLOAD" = 1 ]; then
    step "Enabling $NEW_ICCID"
    # refreshFlag 0: with 1 the eUICC issues a REFRESH mid-session, the QMI logical
    # channel dies and lpac reports InvalidArgument even though the enable went through.
    # The SIM power-cycle below makes the modem re-read the card anyway.
    lpa profile enable "$NEW_ICCID" 0 >/dev/null || die "enable failed: $LPA_LAST_MSG ${LPA_LAST_DATA:-}"
    ok "profile enabled on the eUICC"
fi

# ---- 8. notifications -------------------------------------------------------
step "Sending notifications to the SM-DP+"
pend=$(lpa notification list | jq -r '.data[]? | "  seq \(.seqNumber)  \(.profileManagementOperation)  \(.iccid // "-")  -> \(.notificationAddress)"')
if [ -n "$pend" ]; then
    printf '%s\n' "$pend"
    if lpa notification process -a -r >/dev/null; then ok "notifications delivered and removed"; else warn "notification processing failed: $LPA_LAST_MSG (the profile still works; retry later with 'lpac notification process -a -r')"; fi
else
    info "nothing pending"
fi

# ---- 9. verify on the modem ------------------------------------------------
step "Verifying on the modem"
sim_power_cycle
st=$(wait_for_sim) || die "eUICC stopped answering after enable: '$st'"
slot=$(qmi --uim-get-slot-status)
ENABLED_ICCID=$(printf '%s' "$slot" | sed -n "s/.*ICCID: *\([0-9A-Fa-f]*\).*/\1/p" | head -n1)
kv "Modem sees ICCID" "${ENABLED_ICCID:--}"
info "Profiles on the eUICC now:"
profile_table
if [ "$ENABLE_AFTER_DOWNLOAD" = 1 ]; then
    [ "$ENABLED_ICCID" = "$NEW_ICCID" ] || die "modem reports ICCID '$ENABLED_ICCID', expected '$NEW_ICCID'"
    ok "modem is running the new profile"
fi

# ---- 10. hand the modem back ------------------------------------------------
if [ "$STOP_MODEMMANAGER" = 1 ] && [ "$MM_WAS_ACTIVE" = 1 ]; then
    step "Restarting ModemManager"
    systemctl start ModemManager && ok "ModemManager running"
    MM_WAS_ACTIVE=0   # finish() must not start it twice
    info "waiting for ModemManager to pick the modem up (up to ${MODEM_REAPPEAR_TIMEOUT}s)"
    deadline=$((SECONDS + MODEM_REAPPEAR_TIMEOUT)); mm_iccid=""
    while [ $SECONDS -lt $deadline ]; do
        mm_iccid=$(mmcli -m any -J 2>/dev/null | jq -r '.modem.generic.sim // empty' | xargs -r -I{} mmcli -i {} -J 2>/dev/null | jq -r '.sim.properties.iccid // empty')
        [ -n "$mm_iccid" ] && break
        sleep 5
    done
    if [ -n "$mm_iccid" ]; then
        kv "ModemManager ICCID" "$mm_iccid"
        [ "$ENABLE_AFTER_DOWNLOAD" != 1 ] || [ "$mm_iccid" = "$NEW_ICCID" ] || warn "ModemManager reports a different ICCID than the enabled profile"
    else
        warn "ModemManager has not exposed the SIM yet; check later with: mmcli -m any && mmcli -i 0"
    fi
    if [ "$CHECK_REGISTRATION" = 1 ]; then
        info "waiting for network registration (up to ${REGISTRATION_TIMEOUT}s)"
        deadline=$((SECONDS + REGISTRATION_TIMEOUT)); reg=""
        while [ $SECONDS -lt $deadline ]; do
            reg=$(mmcli -m any -J 2>/dev/null | jq -r '.modem."3gpp"."registration-state" // empty')
            case "$reg" in home|roaming) break ;; esac
            sleep 3
        done
        op=$(mmcli -m any -J 2>/dev/null | jq -r '.modem."3gpp"."operator-name" // "-"')
        kv "Registration" "${reg:-unknown}"
        kv "Operator"     "$op"
        case "$reg" in home|roaming) ok "registered" ;; *) warn "not registered yet (coverage, APN or profile activation on the operator side)" ;; esac
    fi
fi

RESULT="OK: profile $NEW_ICCID installed${ENABLE_AFTER_DOWNLOAD:+ and enabled} on EID $EID"
finish 0
