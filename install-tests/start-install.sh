#!/bin/bash
set -euo pipefail
exec </dev/ttyS0 >/dev/ttyS0 2>&1
echo INSTALL_TEST_STARTED
# Match the liveinst launcher's SELinux handling during installation only.
setenforce 0
export TERM=vt100 LANG=en_US.UTF-8
anaconda --text --kickstart /opt/install-test/install.ks
echo INSTALLER_EXITED_SUCCESSFULLY
sync
systemctl poweroff
