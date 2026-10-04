#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

source_dir=$(pwd)
work=${DESKTOP_WORK:-"$source_dir/desktop-work"}
output=${DESKTOP_OUTPUT:-"$source_dir/desktop-output"}
base_name=AlmaLinux-9.8-x86_64-Live-GNOME.iso
base_url=https://repo.almalinux.org/almalinux/9/live/x86_64
iso_name=Hayavadan-Desktop-x86_64.iso
mkdir -p "$work" "$output"
work=$(realpath "$work")
output=$(realpath "$output")
root="$work/root"
declare -a mounts=()
cleanup() {
    local i
    for ((i=${#mounts[@]}-1; i>=0; i--)); do
        sudo umount "${mounts[i]}" || true
    done
}
trap cleanup EXIT
bind_mount() {
    sudo mount --bind "$1" "$root$1"
    mounts+=("$root$1")
}

echo "Downloading the pinned AlmaLinux 9.8 GNOME base"
curl --fail --location --retry 4 "$base_url/$base_name" -o "$work/base.iso"
curl --fail --location --retry 4 "$base_url/CHECKSUM" -o "$work/CHECKSUM"
base_sha=$(python3 - "$work/CHECKSUM" "$base_name" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
name = re.escape(sys.argv[2])
patterns = [rf'^SHA256\s*\({name}\)\s*=\s*([a-fA-F0-9]{{64}})\s*$',
            rf'^([a-fA-F0-9]{{64}})\s+\*?{name}\s*$']
matches = [m.group(1).lower() for p in patterns for m in re.finditer(p, text, re.M)]
if len(matches) != 1:
    raise SystemExit('Expected one SHA256 checksum for the pinned base ISO')
print(matches[0])
PY
)
printf '%s  %s\n' "$base_sha" "$work/base.iso" | sha256sum -c -

echo "Extracting the base's root filesystem and boot files"
mkdir -p "$work/iso" "$root"
xorriso -osirrox on -indev "$work/base.iso" -extract / "$work/iso"
sudo unsquashfs -no-progress -d "$work/squash" "$work/iso/LiveOS/squashfs.img"
fs_image="$work/squash/LiveOS/rootfs.img"
if [[ ! -f "$fs_image" ]]; then
    echo "This builder requires the AlmaLinux LiveOS/rootfs.img layout" >&2
    exit 1
fi
sudo mount -o loop,rw "$fs_image" "$root"
mounts+=("$root")
sudo tune2fs -m 0 "$fs_image"
df -h "$root"

echo "Compiling the kernel from $(git rev-parse HEAD)"
kernel_build="$work/kernel"
mkdir -p "$kernel_build"
make O="$kernel_build" LOCALVERSION= x86_64_defconfig
bash scripts/kconfig/merge_config.sh -m -O "$kernel_build" \
    "$kernel_build/.config" desktop/kernel.fragment
make O="$kernel_build" LOCALVERSION= olddefconfig
for symbol in CONFIG_EFI_STUB CONFIG_DRM_VIRTIO_GPU CONFIG_EXT4_FS \
              CONFIG_SQUASHFS CONFIG_BLK_DEV_DM CONFIG_DM_SNAPSHOT \
              CONFIG_SECURITY_SELINUX CONFIG_VIRTIO_NET; do
    if ! grep -qx "$symbol=y" "$kernel_build/.config"; then
        echo "Required kernel feature is missing: $symbol" >&2
        exit 1
    fi
done
make O="$kernel_build" LOCALVERSION= -j"$(nproc)" bzImage modules
krel=$(make -s O="$kernel_build" LOCALVERSION= kernelrelease)
printf '%s\n' "$krel" > "$output/kernel-release.txt"
cp "$kernel_build/.config" "$output/kernel.config"

echo "Packaging kernel $krel so RPM and the installer can track it"
payload="$work/payload"
mkdir -p "$payload/boot"
make O="$kernel_build" LOCALVERSION= INSTALL_MOD_PATH="$payload" INSTALL_MOD_STRIP=1 modules_install
# AlmaLinux uses a merged /usr tree; preserve its /lib symlink.
mkdir -p "$payload/usr/lib"
mv "$payload/lib/modules" "$payload/usr/lib/modules"
rmdir "$payload/lib"
rm -f "$payload/usr/lib/modules/$krel/build" "$payload/usr/lib/modules/$krel/source"
cp "$kernel_build/arch/x86/boot/bzImage" "$payload/boot/vmlinuz-$krel"
cp "$kernel_build/System.map" "$payload/boot/System.map-$krel"
cp "$kernel_build/.config" "$payload/boot/config-$krel"
rpm_version=${krel//-/_}
rpm_top="$work/rpm"
mkdir -p "$rpm_top"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
cat > "$rpm_top/SPECS/kernel-desktop.spec" <<EOF
%global _build_id_links none
%global __os_install_post %{nil}
Name: kernel-desktop
Version: $rpm_version
Release: 1
Summary: Upstream Linux kernel for Hayavadan Desktop
License: GPL-2.0-only
URL: https://github.com/thomass-89/linux
BuildArch: x86_64
AutoReqProv: no
Requires: dracut
Requires: grubby
Provides: kernel-uname-r = $krel
Provides: installonlypkg(kernel)

%description
Linux compiled from the user's kernel fork for an experimental desktop.
The matching source and kernel configuration accompany the image release.

%install
mkdir -p %{buildroot}
cp -a "$payload/." %{buildroot}/

%posttrans
/sbin/depmod -a $krel
/usr/bin/kernel-install add $krel /boot/vmlinuz-$krel || exit 1

%preun
if [ \$1 -eq 0 ]; then
    /usr/bin/kernel-install remove $krel || :
fi

%files
/boot/vmlinuz-$krel
/boot/System.map-$krel
/boot/config-$krel
/usr/lib/modules/$krel
EOF
rpmbuild --define "_topdir $rpm_top" -bb "$rpm_top/SPECS/kernel-desktop.spec"
kernel_rpm=$(find "$rpm_top/RPMS" -name '*.rpm' -print -quit)
cp "$kernel_rpm" "$output/"
sudo cp "$kernel_rpm" "$root/tmp/kernel-desktop.rpm"
# Only the initial live-image assembly defers hooks: build its initramfs explicitly.
sudo chroot "$root" rpm -ivh --noscripts /tmp/kernel-desktop.rpm
sudo rm "$root/tmp/kernel-desktop.rpm"

echo "Integrating the custom kernel into the desktop"
for path in /dev /proc /sys; do bind_mount "$path"; done
sudo mkdir -p "$root/run/desktop-build"
sudo mkdir -p "$root/usr/local/libexec"
sudo cp desktop/guest-smoke.sh "$root/usr/local/libexec/desktop-smoke"
sudo chmod 755 "$root/usr/local/libexec/desktop-smoke"
cat > "$work/desktop-smoke.service" <<'EOF'
[Unit]
Description=Desktop build verification in the dedicated test VM
After=display-manager.service NetworkManager.service
ConditionPathExists=/sys/devices/virtual/dmi/id/product_name

[Service]
Type=simple
ExecCondition=/usr/bin/grep -qxF "Hayavadan Desktop Build Test" /sys/devices/virtual/dmi/id/product_name
ExecStart=/usr/local/libexec/desktop-smoke
RuntimeMaxSec=600

[Install]
WantedBy=graphical.target
EOF
sudo cp "$work/desktop-smoke.service" "$root/etc/systemd/system/desktop-smoke.service"
sudo chroot "$root" systemctl enable desktop-smoke.service
printf '%s\n' "$krel" | sudo tee "$root/etc/desktop-kernel-release" >/dev/null
sudo mkdir -p "$root/usr/share/doc/hayavadan-desktop"
sudo cp desktop/README.md "$root/usr/share/doc/hayavadan-desktop/README.md"
python3 - "$root/usr/lib/os-release" "$work/os-release" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
text = re.sub(r'^NAME=.*$', 'NAME="Hayavadan Desktop"', text, flags=re.M)
text = re.sub(r'^PRETTY_NAME=.*$', 'PRETTY_NAME="Hayavadan Desktop (AlmaLinux 9.8 base)"', text, flags=re.M)
open(sys.argv[2], 'w', encoding='utf-8').write(text)
PY
sudo cp "$work/os-release" "$root/usr/lib/os-release"
cat > "$work/build-info.json" <<EOF
{
  "name": "Hayavadan Desktop",
  "architecture": "x86_64",
  "base": "$base_name",
  "base_url": "$base_url/$base_name",
  "base_sha256": "$base_sha",
  "kernel_release": "$krel",
  "source_repository": "https://github.com/thomass-89/linux",
  "source_commit": "$(git rev-parse HEAD)",
  "kernel_config_sha256": "$(sha256sum "$output/kernel.config" | cut -d' ' -f1)",
  "secure_boot": "unsigned custom kernel; Secure Boot disabled for this build",
  "installer_validation": "installer included; disk installation not automatically tested"
}
EOF
cp "$work/build-info.json" "$output/build-info.json"
sudo cp "$work/build-info.json" "$root/usr/share/doc/hayavadan-desktop/build-info.json"
sudo chroot "$root" depmod -a "$krel"
sudo chroot "$root" dracut --force --no-hostonly --no-hostonly-cmdline \
    --add 'dmsquash-live' \
    --add-drivers 'virtio_pci virtio_blk virtio_net virtio_gpu' \
    "/boot/initramfs-$krel.img" "$krel"
sudo chroot "$root" grubby --add-kernel="/boot/vmlinuz-$krel" \
    --initrd="/boot/initramfs-$krel.img" --title="Hayavadan Desktop ($krel)" \
    --copy-default --make-default
sudo chroot "$root" restorecon -RF /usr/local/libexec/desktop-smoke \
    /etc/systemd/system/desktop-smoke.service /etc/desktop-kernel-release \
    /usr/share/doc/hayavadan-desktop /usr/lib/modules/"$krel" /boot /usr/lib/os-release
sudo chroot "$root" rpm -q kernel-desktop
sudo cp "$root/boot/vmlinuz-$krel" "$work/iso/images/pxeboot/vmlinuz"
sudo cp "$root/boot/initramfs-$krel.img" "$work/iso/images/pxeboot/initrd.img"
# Older lorax layouts can carry additional copies used by isolinux.
for path in isolinux/vmlinuz isolinux/initrd.img; do
    if [[ -f "$work/iso/$path" ]]; then
        case "$path" in
            */vmlinuz) sudo cp "$root/boot/vmlinuz-$krel" "$work/iso/$path" ;;
            */initrd.img) sudo cp "$root/boot/initramfs-$krel.img" "$work/iso/$path" ;;
        esac
    fi
done

cleanup
mounts=()
echo "Compressing the modified desktop filesystem"
sudo rm "$work/iso/LiveOS/squashfs.img"
sudo mksquashfs "$work/squash" "$work/iso/LiveOS/squashfs.img" \
    -comp xz -b 1M -noappend -no-progress -processors "$(nproc)"

echo "Rebuilding the bootable ISO, preserving the base's BIOS/UEFI boot records and label"
declare -a maps=(-map "$work/iso/LiveOS/squashfs.img" /LiveOS/squashfs.img \
    -map "$work/iso/images/pxeboot/vmlinuz" /images/pxeboot/vmlinuz \
    -map "$work/iso/images/pxeboot/initrd.img" /images/pxeboot/initrd.img)
for path in isolinux/vmlinuz isolinux/initrd.img; do
    if [[ -f "$work/iso/$path" ]]; then maps+=(-map "$work/iso/$path" "/$path"); fi
done
if [[ -f "$work/iso/.treeinfo" ]]; then
    python3 - "$work/iso" <<'PY'
import configparser, hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
path = root / '.treeinfo'
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
config.read(path)
if config.has_section('checksums'):
    for name, old in config.items('checksums'):
        file = root / name
        if not file.is_file():
            continue
        algorithm = old.split(':', 1)[0]
        digest = hashlib.new(algorithm)
        with file.open('rb') as source:
            for block in iter(lambda: source.read(8 * 1024 * 1024), b''):
                digest.update(block)
        config.set('checksums', name, algorithm + ':' + digest.hexdigest())
    with path.open('w') as destination:
        config.write(destination)
PY
    maps+=(-map "$work/iso/.treeinfo" /.treeinfo)
fi
xorriso -indev "$work/base.iso" -outdev "$output/$iso_name" \
    "${maps[@]}" -boot_image any replay
implantisomd5 --force "$output/$iso_name"
xorriso -indev "$output/$iso_name" -report_el_torito plain

echo "Saving the exact corresponding source"
git archive --format=tar HEAD | zstd -T0 -10 -o "$output/linux-source.tar.zst"
cp desktop/join-image.py "$output/"
cp desktop/README.md "$output/README.md"
cd "$output"
sha256sum "$iso_name" > ISO-SHA256SUMS
echo "Image assembled: $output/$iso_name"
