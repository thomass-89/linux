#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
exec > >(tee /run/desktop-smoke.log /dev/ttyS0) 2>&1
trap 'status=$?; if ((status != 0)); then echo DESKTOP_SMOKE_FAILED; systemctl --no-pager --failed; journalctl -b -p err --no-pager -n 40; fi' EXIT
expected=$(cat /etc/desktop-kernel-release)
test "$(uname -r)" = "$expected"
test "$(getenforce)" = Enforcing
rpm -q kernel-desktop firefox libreoffice-writer anaconda-live
systemctl is-active NetworkManager
deadline=$((SECONDS + 480))
while ! pgrep -u liveuser -x gnome-shell >/dev/null; do
    if ((SECONDS > deadline)); then
        echo "The live user's GNOME desktop did not start" >&2
        exit 1
    fi
    sleep 5
done
systemctl is-active gdm
ip -4 route show default | grep -q .
# The QEMU user network's gateway is local; no remote site is needed for this check.
gateway=$(ip -4 route show default | awk 'NR==1 {print $3}')
ping -c 1 -W 5 "$gateway"
# The inner shell expands HOME as the live user.
# shellcheck disable=SC2016
runuser -u liveuser -- bash -c \
    'printf "Desktop file write verified\n" > "$HOME/desktop-build-test.txt"; test -s "$HOME/desktop-build-test.txt"; rm "$HOME/desktop-build-test.txt"'
echo "Kernel: $(uname -r)"
echo "SELinux: $(getenforce)"
echo "GNOME: liveuser session running"
echo "Network: DHCP route and gateway verified"
echo "Filesystem: liveuser home is writable"
echo DESKTOP_SMOKE_OK
