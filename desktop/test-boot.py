#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Boot the delivered ISO's own bootloader and require guest-side desktop checks."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from PIL import Image


class Monitor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(15)
        try:
            self.sock.connect(str(path))
        except OSError:
            self.sock.close()
            raise
        self.file = self.sock.makefile('rwb')
        json.loads(self.file.readline())
        self.execute('qmp_capabilities')

    def execute(self, command, arguments=None):
        request = {'execute': command, 'id': command}
        if arguments is not None:
            request['arguments'] = arguments
        self.file.write(json.dumps(request).encode() + b'\n')
        self.file.flush()
        while True:
            result = json.loads(self.file.readline())
            if result.get('id') == command:
                if 'error' in result:
                    raise RuntimeError(result['error'])
                return result.get('return')

    def close(self):
        self.file.close()
        self.sock.close()


def test_boot(output, mode):
    iso = output / 'Hayavadan-Desktop-x86_64.iso'
    if not iso.is_file():
        raise RuntimeError('The completed ISO is missing; inspect build.log first')
    serial = output / f'{mode}-serial.log'
    emulator_log = output / f'{mode}-qemu.log'
    kvm = os.access('/dev/kvm', os.R_OK | os.W_OK)
    with tempfile.TemporaryDirectory(prefix='desktop-qemu-') as temp:
        temp = Path(temp)
        qmp_path = temp / 'qmp.sock'
        command = [
            'qemu-system-x86_64', '-machine', 'q35',
            '-accel', 'kvm' if kvm else 'tcg,thread=multi',
            '-cpu', 'host' if kvm else 'max', '-smp', '2', '-m', '4096',
            '-boot', 'order=d,menu=off', '-cdrom', str(iso),
            '-device', 'virtio-vga', '-device', 'qemu-xhci',
            '-device', 'usb-tablet',
            '-netdev', 'user,id=net0', '-device', 'virtio-net-pci,netdev=net0',
            '-smbios', 'type=1,product=Hayavadan Desktop Build Test',
            '-display', 'none', '-serial', f'file:{serial}',
            '-qmp', f'unix:{qmp_path},server=on,wait=off', '-no-reboot',
        ]
        if mode == 'uefi':
            firmware = Path('/usr/share/OVMF')
            code = firmware / 'OVMF_CODE_4M.fd'
            variables = firmware / 'OVMF_VARS_4M.fd'
            if not code.is_file() or not variables.is_file():
                raise RuntimeError('Non-Secure-Boot OVMF firmware is unavailable')
            shutil.copyfile(variables, temp / 'vars.fd')
            command += ['-drive', f'if=pflash,format=raw,readonly=on,file={code}',
                        '-drive', f'if=pflash,format=raw,file={temp / "vars.fd"}']
        start = time.monotonic()
        monitor = None
        with emulator_log.open('wb') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                while monitor is None:
                    if process.poll() is not None or time.monotonic() - start > 30:
                        raise RuntimeError(f'{mode}: QEMU did not start; see {emulator_log}')
                    if qmp_path.exists():
                        try:
                            monitor = Monitor(qmp_path)
                        except (FileNotFoundError, ConnectionRefusedError):
                            pass
                    if monitor is None:
                        time.sleep(0.5)
                passed = False
                while time.monotonic() - start < 1200:
                    text = serial.read_text(errors='replace') if serial.exists() else ''
                    if 'DESKTOP_SMOKE_FAILED' in text:
                        break
                    if 'DESKTOP_SMOKE_OK' in text:
                        passed = True
                        break
                    if process.poll() is not None:
                        break
                    time.sleep(5)
                ppm = temp / 'screen.ppm'
                if process.poll() is None:
                    monitor.execute('screendump', {'filename': str(ppm)})
                    with Image.open(ppm) as picture:
                        picture.save(output / f'{mode}-desktop.png')
                if not passed:
                    raise RuntimeError(f'{mode}: ISO desktop boot failed; see {serial}')
                result = {'firmware': mode, 'passed': True,
                          'accelerator': 'kvm' if kvm else 'tcg',
                          'seconds': round(time.monotonic() - start, 1),
                          'checks': ['ISO bootloader', 'custom kernel', 'SELinux enforcing',
                                     'GNOME user session', 'desktop applications installed',
                                     'DHCP and gateway', 'user file write']}
                print(json.dumps(result), flush=True)
                return result
            finally:
                if monitor:
                    monitor.close()
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    output = Path(sys.argv[1]).resolve()
    results = [test_boot(output, mode) for mode in ('bios', 'uefi')]
    (output / 'test-results.json').write_text(json.dumps(results, indent=2) + '\n')
