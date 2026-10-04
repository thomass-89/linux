# Hayavadan Desktop

An experimental x86_64 live desktop built from this Linux fork and the official
AlmaLinux 9.8 GNOME live image. It includes GNOME, Firefox, LibreOffice, GNOME
Files, NetworkManager, and the AlmaLinux graphical installer. The kernel is
compiled from the exact commit recorded in `build-info.json` and packaged as
`kernel-desktop`, while retaining the base distribution's kernel as a fallback.

This is a personal derivative, not Red Hat Enterprise Linux or a supported
AlmaLinux kernel. The current branch uses an upstream release candidate.

## Download and boot

The **Build Hayavadan Desktop** workflow publishes a prerelease only after the
finished ISO boots through its own bootloader in both BIOS and UEFI test VMs.
Release assets contain the ISO in 1 GiB parts to stay below per-file size limits.

1. Download every `Hayavadan-Desktop-x86_64.iso.part-*` file, `join-image.py`,
   and `ISO-SHA256SUMS` into the same folder.
2. Run `python3 join-image.py` on Linux/macOS, or `py join-image.py` on Windows
   with Python 3 installed. The program joins the parts and verifies SHA256.
3. Attach the resulting ISO as a VM's CD/DVD. Use x86_64, at least 4 GB RAM,
   two CPUs, and Secure Boot disabled. The custom kernel is unsigned.
4. Boot the first live entry. GNOME automatically opens a `liveuser` session.
   Changes in the live session are temporary. Use a disposable VM first.

The graphical installer is inherited from the AlmaLinux image; automatic checks
cover the live desktop, not a disk installation. Do not rely on an installation
onto valuable disks before testing the installer in a disposable VM.

## What the build verifies

The test VM must run the compiled kernel with SELinux enforcing, start GNOME
for the live user, have the desktop packages installed, obtain a DHCP route,
reach the VM network gateway, and write a file in the user's home directory.
Screenshots, serial logs, `test-results.json`, and build provenance accompany
each successful release. Physical hardware and browser web rendering are not
automatically tested. Drivers in `kernel.fragment` focus on desktop VMs and
common x86_64 desktop hardware; support for a specific PC is not guaranteed.

The smoke service activates only when a VM explicitly supplies the test DMI
product name `Hayavadan Desktop Build Test`. It is inactive in normal use.

## Rebuild

On GitHub, changes under `desktop/` or its workflow on `my-experiment` trigger
a build. The workflow uses a standard public Ubuntu runner, no paid larger
runner, no cache, and release assets for the large image. Small diagnostics are
retained as an Actions artifact for one day. It may require enabling Actions
in a newly created fork.

Locally, use an Ubuntu 24.04 x86_64 build host with sudo, about 35 GB free disk
space, 8 GB RAM, and the packages listed in the workflow. From the repository
root:

```sh
export DESKTOP_WORK=/path/with/space/desktop-build
export DESKTOP_OUTPUT="$PWD/desktop-output"
bash desktop/build.sh
python3 desktop/test-boot.py "$DESKTOP_OUTPUT"
```

The base image's checksum is read from AlmaLinux's HTTPS CHECKSUM file and
verified before extraction. The rebuild preserves the original ISO label and
boot records. Its original boot-menu names and artwork remain visible.
This recipe records exact source and configuration but does not promise
byte-for-byte reproducible images: package build tools and timestamps may vary.

AlmaLinux repositories provide userspace updates. Updates to this custom
kernel require rebuilding. The custom RPM's install/removal hooks integrate
with `kernel-install`; it is not signed or backed by an automatic update feed.

## Source and licensing

The release includes `linux-source.tar.zst`, an archive of the exact kernel and
build-recipe commit, and `kernel.config`. The Linux tree's COPYING and LICENSES
directory provide its license terms. New build scripts are GPL-2.0-only.
The base userspace consists of AlmaLinux/EPEL packages with their individual
licenses; the original image is available at
https://repo.almalinux.org/almalinux/9/live/x86_64/ and corresponding package
sources at https://repo.almalinux.org/almalinux/9/BaseOS/Source/ and
https://repo.almalinux.org/almalinux/9/AppStream/Source/ plus
https://dl.fedoraproject.org/pub/epel/9/Everything/source/ .
