#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
output=${DESKTOP_OUTPUT:?DESKTOP_OUTPUT is required}
cd "$output"
test -s test-results.json
python3 - <<'PY'
import json
results = json.load(open('test-results.json', encoding='utf-8'))
assert {r['firmware'] for r in results if r['passed']} == {'bios', 'uefi'}
PY
iso=Experimental-Desktop-x86_64.iso
# Release assets avoid storing a multi-GB image in billed Actions artifacts.
# Keep each downloadable part comfortably below GitHub's per-file limits.
split -b 1024M -d -a 3 --numeric-suffixes=1 "$iso" "$iso.part-"
sha256sum "$iso".part-* ./*.rpm linux-source.tar.zst kernel.config \
    join-image.py > SHA256SUMS
tag="desktop-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
cat > release-notes.md <<EOF
Experimental Desktop: AlmaLinux 9.8 GNOME with Linux $(cat kernel-release.txt), compiled from this fork.

Both BIOS and UEFI VM boots passed: the custom kernel, enforcing SELinux, live user's GNOME desktop, installed desktop applications, DHCP networking, and file writes were checked. Screenshots and test-results.json are attached.

Download every \`$iso.part-*\` file, \`join-image.py\`, and \`ISO-SHA256SUMS\` into one folder, then run \`python3 join-image.py\` (Windows: \`py join-image.py\`). It creates and checks the bootable ISO. Use it as a VM CD/DVD first, with at least 4 GB RAM, two CPUs, and Secure Boot off.

Firefox, LibreOffice, GNOME Files, NetworkManager and the AlmaLinux graphical installer are included. The live session logs in as liveuser. Disk installation is included but has not been automatically tested; this release's verification covers the live desktop. Custom kernel updates require rebuilding; AlmaLinux supplies userspace updates.

This is an experimental derivative, using a release-candidate kernel, and is not Red Hat Enterprise Linux or a supported AlmaLinux kernel. The compiled kernel is unsigned. The original AlmaLinux kernel remains installed as a fallback. The ISO's original AlmaLinux volume label and boot-menu artwork are retained to preserve boot compatibility.

Matching kernel source, the full build configuration, kernel RPM, checksums, and build provenance are included. Build source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/tree/$GITHUB_SHA/desktop
EOF
declare -a assets=("$iso".part-* ISO-SHA256SUMS SHA256SUMS join-image.py \
    README.md linux-source.tar.zst kernel.config ./*.rpm build-info.json \
    test-results.json bios-desktop.png uefi-desktop.png bios-serial.log uefi-serial.log)
gh release create "$tag" "${assets[@]}" --repo "$GITHUB_REPOSITORY" \
    --target "$GITHUB_SHA" --title "Experimental Desktop experimental build" \
    --prerelease --notes-file release-notes.md
printf '### Tested desktop image\n\n[Download the release](%s/%s/releases/tag/%s)\n' \
    "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$tag" >> "$GITHUB_STEP_SUMMARY"
