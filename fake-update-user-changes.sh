#!/bin/sh
# fake-update-user-changes.sh - test scaffolding for the fake-update-build branch. NOT shipped in
# the image; run it as root inside the OLD profile (the one built from the previous _stock) to play
# the part of a user who has been living in that profile. Each change here pairs with a change the
# fake-update build makes to the new _stock, so migrate-profile has to resolve every case:
#
#   this script (source profile)          fake-update build (destination base)   tested path
#   adds Tailscale's repo + keyring and   adds a trixie-backports source         apt sources, keyring and
#     installs tailscale (not in Debian)                                           packages replay in that order
#   installs jq                           -                                      user-added package is replayed
#   purges blueman                        ships blueman                          user-removed package is purged
#   -                                     adds tree                              new-base package is left alone
#   -                                     drops kde-spectacle                    dropped package is NOT reinstalled
#   UPower.conf PercentageLow             UPower.conf TimeLow                    3-way merge, no conflict
#   bluetooth main.conf FastConnectable   same line, different value             conflict -> .migrate-conflict
#   deletes modules-load.d/binfmt_misc    edits the same file                    delete versus modify
#   adds apt.conf.d/82-user-test          adds apt.conf.d/81-fake-update         apt config merged before replay
#   adds testuser + group memberships     adds the fakeupd service account       per-entry account merge
#   writes /etc/flipper-fake-update.dat   ships a different one                  binary conflict -> .migrate-theirs
#   edits /etc/hosts                      -                                      plain carry
#   deletes /etc/debconf.conf             -                                      plain delete
#   writes caches and a stale sidecar     -                                      skipped as noise
#
# Re-runnable: every step is idempotent.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }

# A genuinely foreign repository: Tailscale's, signed with its own key, serving a package Debian
# does not carry at all. That is what makes it a real test of the ordering: the destination profile
# can only install tailscale if the source list and keyring reached it before the package replay ran.
TS_LIST=/etc/apt/sources.list.d/tailscale.list
TS_KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg

say "foreign repo: add Tailscale's repo and install tailscale (not in Debian)"
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o "$TS_KEYRING"
printf 'deb [signed-by=%s] https://pkgs.tailscale.com/stable/debian trixie main\n' "$TS_KEYRING" > "$TS_LIST"
apt-get update
dpkg -s tailscale >/dev/null 2>&1 || apt-get install -y tailscale
# the package is the point, not the daemon; keep it from running or holding state
systemctl disable --now tailscaled 2>/dev/null || true
dpkg -s tailscale | grep -m1 ^Version | sed 's/^/  /'
apt-cache policy tailscale | sed -n 's/^ *500 /  from: /p' | head -2

say "packages: install jq (user-added), purge blueman (user-removed)"
dpkg -s jq >/dev/null 2>&1 || apt-get install -y jq
dpkg -s blueman >/dev/null 2>&1 && apt-get purge -y blueman || echo "  blueman already absent"

say "clean merge: UPower.conf PercentageLow (the build changes TimeLow)"
sed -i 's/^PercentageLow=.*/PercentageLow=15.0/' /etc/UPower/UPower.conf
grep -n '^PercentageLow\|^TimeLow' /etc/UPower/UPower.conf | sed 's/^/  /'

say "conflict: bluetooth main.conf, same line the build changes"
sed -i 's/^FastConnectable = .*/FastConnectable = true  # user: keep fast connect/' /etc/bluetooth/main.conf
grep -n '^FastConnectable' /etc/bluetooth/main.conf | sed 's/^/  /'

say "delete versus modify: remove modules-load.d/binfmt_misc.conf (the build edits it)"
rm -f /etc/modules-load.d/binfmt_misc.conf
echo "  present: $([ -e /etc/modules-load.d/binfmt_misc.conf ] && echo yes || echo no)"

say "apt config: add our own drop-in next to the build's"
printf 'APT::Get::Assume-Yes "false";\n' > /etc/apt/apt.conf.d/82-user-test

say "accounts: testuser in sudo and audio (the build adds the fakeupd service account)"
id testuser >/dev/null 2>&1 || useradd -m -s /bin/bash testuser
echo 'testuser:testpass' | chpasswd
for g in sudo audio; do id -nG testuser | tr ' ' '\n' | grep -qx "$g" || usermod -aG "$g" testuser; done
id testuser | sed 's/^/  /'

say "binary conflict: our /etc/flipper-fake-update.dat differs from the build's"
printf 'USER\000ASSET\377\000local\n' > /etc/flipper-fake-update.dat
od -c /etc/flipper-fake-update.dat | head -2 | sed 's/^/  /'

say "plain carry and plain delete: /etc/hosts edit, /etc/debconf.conf removal"
grep -q 'fake-update-test' /etc/hosts || printf '10.0.0.9\tfake-update-test\n' >> /etc/hosts
rm -f /etc/debconf.conf
tail -2 /etc/hosts | sed 's/^/  /'

say "noise: a cache file and a stale migration sidecar must both be skipped"
mkdir -p /root/.cache && date > /root/.cache/fake-update-junk
printf 'stale sidecar\n' > /etc/hosts.migrate-conflict

say "done; source profile is ready to migrate"
