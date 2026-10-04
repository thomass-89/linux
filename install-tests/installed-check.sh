#!/bin/bash
set -euo pipefail
exec >/dev/ttyS0 2>&1
trap 'status=$?; if ((status)); then echo INSTALLED_CHECK_FAILED; systemctl --failed --no-pager; journalctl -b -p err -n 50 --no-pager; fi' EXIT
test "$(uname -r)" = "$(cat /etc/desktop-kernel-release)"
test "$(getenforce)" = Enforcing
source=$(findmnt -n -o SOURCE /)
case "$source" in /dev/vda*|/dev/mapper/*) ;; *) echo "Unexpected root: $source"; exit 1;; esac
if grep -q 'rd.live.image' /proc/cmdline; then exit 1; fi
rpm -q kernel-desktop firefox libreoffice-writer
deadline=$((SECONDS + 600))
until pgrep -u testuser -x gnome-shell >/dev/null && ip -4 route show default | grep -q .; do
    ((SECONDS < deadline)) || exit 1
    sleep 5
done
systemctl is-active gdm NetworkManager
gateway=$(ip -4 route show default | awk 'NR==1 {print $3}')
ping -c 1 -W 5 "$gateway"
marker=/home/testuser/install-persistence.txt
if test -f "$marker"; then
    test "$(cat "$marker")" = 'persisted across disk reboot'
    echo INSTALLED_SECOND_BOOT_OK
else
    runuser -u testuser -- sh -c 'echo "persisted across disk reboot" > /home/testuser/install-persistence.txt'
    echo INSTALLED_FIRST_BOOT_OK
fi
echo "Installed kernel: $(uname -r); root: $source; SELinux: $(getenforce)"
sync
# Allow the host to capture the running desktop before clean shutdown.
sleep 15
systemctl poweroff
