#!/usr/bin/env python3
"""Install the released live filesystem, then boot only its target disk twice."""
import gzip
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('live_tests', REPO / 'desktop/test-boot.py')
live_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_tests)
OUTPUT = Path(sys.argv[1]).resolve()
OUTPUT.mkdir(parents=True, exist_ok=True)
ISO = OUTPUT / 'Experimental-Desktop-x86_64.iso'


def prepare(temp):
    for name in ('vmlinuz', 'initrd.img'):
        subprocess.run(['xorriso', '-osirrox', 'on', '-indev', str(ISO),
                        '-extract', '/images/pxeboot/' + name, str(temp / name)], check=True)
    overlay = temp / 'overlay'
    payload = overlay / 'install-test'
    payload.mkdir(parents=True)
    for name in ('start-install.sh', 'installed-check.sh', 'install.ks'):
        shutil.copyfile(REPO / 'install-tests' / name, payload / name)
    hook = overlay / 'usr/lib/dracut/hooks/pre-pivot/99-install-test.sh'
    hook.parent.mkdir(parents=True)
    hook.write_text('''#!/bin/sh
mkdir -p /sysroot/opt/install-test /sysroot/etc/systemd/system/multi-user.target.wants
cp -a /install-test/. /sysroot/opt/install-test/
chmod 755 /sysroot/opt/install-test/*.sh
cat > /sysroot/etc/systemd/system/install-test.service <<'UNIT'
[Unit]
Description=Disposable VM installation test
After=NetworkManager.service
[Service]
Type=simple
ExecStart=/bin/bash /opt/install-test/start-install.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../install-test.service /sysroot/etc/systemd/system/multi-user.target.wants/install-test.service
''')
    hook.chmod(0o755)
    names = b'\0'.join(str(p.relative_to(overlay)).encode() for p in sorted(overlay.rglob('*'))) + b'\0'
    archive = subprocess.run(['cpio', '--null', '-o', '-H', 'newc'], cwd=overlay,
                             input=names, stdout=subprocess.PIPE, check=True).stdout
    with (temp / 'initrd.img').open('ab') as target:
        target.write(gzip.compress(archive))


def boot(temp, mode, phase):
    serial = OUTPUT / f'{mode}-{phase}-serial.log'
    monitor_path = temp / 'qmp.sock'
    monitor_path.unlink(missing_ok=True)
    kvm = os.access('/dev/kvm', os.R_OK | os.W_OK)
    command = ['qemu-system-x86_64', '-machine', 'q35',
               '-accel', 'kvm' if kvm else 'tcg,thread=multi',
               '-cpu', 'host' if kvm else 'max', '-smp', '2', '-m', '4096',
               '-drive', f'file={temp / "disk.qcow2"},format=qcow2,if=virtio',
               '-device', 'virtio-vga', '-device', 'qemu-xhci', '-device', 'usb-tablet',
               '-netdev', 'user,id=n0', '-device', 'virtio-net-pci,netdev=n0',
               '-smbios', 'type=1,product=Experimental Desktop Installation Test',
               '-display', 'none', '-serial', f'file:{serial}',
               '-qmp', f'unix:{monitor_path},server=on,wait=off', '-no-reboot']
    if mode == 'uefi':
        command += ['-drive', 'if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd',
                    '-drive', f'if=pflash,format=raw,file={temp / "vars.fd"}']
    if phase == 'install':
        # Only the installation environment receives the automation overlay.
        # Subsequent boots use the installed bootloader, with no ISO/initrd supplied.
        command += ['-cdrom', str(ISO), '-kernel', str(temp / 'vmlinuz'),
                    '-initrd', str(temp / 'initrd.img'), '-append',
                    'root=live:CDLABEL=AlmaLinux-9_8-x86_64-Live-GNOME rd.live.image '
                    'enforcing=0 console=ttyS0,115200n8 console=tty0']
        marker, timeout = 'INSTALLER_POST_OK', 2400
    else:
        command += ['-boot', 'order=c']
        marker = 'INSTALLED_FIRST_BOOT_OK' if phase == 'first-boot' else 'INSTALLED_SECOND_BOOT_OK'
        timeout = 900
    print(f'{mode}: {phase} started', flush=True)
    start = time.monotonic()
    monitor = None
    captured = False
    with (OUTPUT / f'{mode}-{phase}-qemu.log').open('wb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            while time.monotonic() - start < timeout:
                if monitor is None and monitor_path.exists():
                    try:
                        monitor = live_tests.Monitor(monitor_path)
                    except (FileNotFoundError, ConnectionRefusedError):
                        pass
                text = serial.read_text(errors='replace') if serial.exists() else ''
                if marker in text and monitor and not captured and process.poll() is None:
                    ppm = temp / 'screen.ppm'
                    monitor.execute('screendump', {'filename': str(ppm)})
                    with Image.open(ppm) as picture:
                        picture.save(OUTPUT / f'{mode}-{phase}.png')
                    captured = True
                if process.poll() is not None:
                    if marker in text and process.returncode == 0:
                        return {'phase': phase, 'passed': True, 'seconds': round(time.monotonic()-start, 1)}
                    raise RuntimeError(f'{mode} {phase}: guest exited without success')
                if any(x in text for x in ('INSTALLED_CHECK_FAILED', 'dracut: FATAL:',
                                          'Kernel panic - not syncing:', 'Traceback (most recent call last):')):
                    raise RuntimeError(f'{mode} {phase}: fatal error in guest log')
                time.sleep(3)
            raise RuntimeError(f'{mode} {phase}: timed out')
        finally:
            if monitor:
                if process.poll() is None and not captured:
                    try:
                        ppm = temp / 'failure.ppm'
                        monitor.execute('screendump', {'filename': str(ppm)})
                        with Image.open(ppm) as picture:
                            picture.save(OUTPUT / f'{mode}-{phase}.png')
                    except Exception:
                        pass
                monitor.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if serial.exists():
                print(serial.read_text(errors='replace')[-18000:], flush=True)


results = []
for mode in ('bios', 'uefi'):
    result = {'firmware': mode, 'passed': False, 'stages': []}
    try:
        with tempfile.TemporaryDirectory(prefix=f'install-{mode}-') as folder:
            temp = Path(folder)
            prepare(temp)
            subprocess.run(['qemu-img', 'create', '-f', 'qcow2', str(temp / 'disk.qcow2'), '32G'], check=True)
            if mode == 'uefi':
                shutil.copyfile('/usr/share/OVMF/OVMF_VARS_4M.fd', temp / 'vars.fd')
            for phase in ('install', 'first-boot', 'second-boot'):
                result['stages'].append(boot(temp, mode, phase))
            result['passed'] = True
    except Exception as error:
        result['error'] = str(error)
    results.append(result)
    (OUTPUT / 'installation-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(result), flush=True)
sys.exit(0 if all(x['passed'] for x in results) else 1)
