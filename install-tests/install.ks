text
liveimg --url=file:///run/initramfs/live/LiveOS/squashfs.img
lang en_US.UTF-8
keyboard us
timezone Asia/Kolkata --utc
rootpw --lock
user --name=testuser --groups=wheel --password=vm-install-test --plaintext
network --bootproto=dhcp --device=link --activate
selinux --enforcing
firewall --enabled
services --enabled=gdm,NetworkManager
firstboot --disable
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=plain --fstype=ext4 --nohome --noswap
bootloader --boot-drive=vda --append="console=ttyS0,115200n8 console=tty0"
poweroff

%post --nochroot --erroronfail --log=/tmp/install-test-copy.log
install -D -m 0755 /opt/install-test/installed-check.sh /mnt/sysroot/usr/local/libexec/installed-check
%end

%post --erroronfail --log=/root/install-test-post.log
cat > /etc/systemd/system/installed-check.service <<'UNIT'
[Unit]
Description=Disposable VM installed desktop verification
After=NetworkManager.service display-manager.service
[Service]
Type=simple
ExecStart=/usr/local/libexec/installed-check
TimeoutStartSec=700
[Install]
WantedBy=graphical.target
UNIT
mkdir -p /etc/systemd/system/graphical.target.wants
ln -sf ../installed-check.service /etc/systemd/system/graphical.target.wants/installed-check.service
rm -f /etc/systemd/system/multi-user.target.wants/install-test.service
sed -i '/^AutomaticLoginEnable=/d; /^AutomaticLogin=/d' /etc/gdm/custom.conf
sed -i '/^\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=testuser' /etc/gdm/custom.conf
systemctl set-default graphical.target
restorecon -RF /usr/local/libexec/installed-check /etc/systemd/system /etc/gdm
echo INSTALLER_POST_OK > /dev/ttyS0
%end
