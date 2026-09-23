#!/usr/bin/env python3
"""Package the generated 1024px artwork into the macOS ICNS size representations."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'output/imagegen/container-sweeper-icon.png'
info = subprocess.check_output(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(source)], text=True)
if 'pixelWidth: 1024' not in info or 'pixelHeight: 1024' not in info:
    raise SystemExit('The icon master must be 1024 by 1024 pixels.')
(ROOT / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='icon-', dir=ROOT / '.build') as temporary:
    iconset = Path(temporary) / 'AppIcon.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            suffix = '@2x' if scale == 2 else ''
            target = iconset / f'icon_{size}x{size}{suffix}.png'
            subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels), str(source), '--out', str(target)], check=True, stdout=subprocess.DEVNULL)
    destination = ROOT / 'Packaging/AppIcon.icns'
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(destination)], check=True)
print(destination)
