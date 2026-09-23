#!/usr/bin/env python3
"""Build an isolated debug app fixture. Open the printed path to inspect the UI."""
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--english', action='store_true')
parser.add_argument('--light', action='store_true')
parser.add_argument('--compact', action='store_true')
parser.add_argument('--state', choices=['default', 'merged', 'empty', 'destructive', 'load-error', 'busy'], default='default')
args = parser.parse_args()
subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
bin_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
variant = f"{'en' if args.english else 'ja'}-{'light' if args.light else 'dark'}-{args.state}"
if args.compact:
    variant += '-compact'
app = ROOT / '.build' / 'previews' / f'Container Sweeper {variant}.app'
for directory in ['MacOS', 'Resources']:
    (app / 'Contents' / directory).mkdir(parents=True, exist_ok=True)
shutil.copy2(bin_dir / 'ContainerSweeper', app / 'Contents/MacOS/ContainerSweeper')
resource = 'ContainerSweeper_ContainerSweeper.bundle'
shutil.copytree(bin_dir / resource, app / 'Contents/Resources' / resource, dirs_exist_ok=True)
shutil.copy2(ROOT / 'Packaging/AppIcon.icns', app / 'Contents/Resources/AppIcon.icns')
with (ROOT / 'Packaging/Info.plist').open('rb') as file:
    info = plistlib.load(file)
info['CFBundleIdentifier'] = f'dev.containersweeper.preview.{variant}'
info['CFBundleName'] = f'Container Sweeper Preview {variant}'
info['SweeperPreviewArguments'] = ['--preview-ui', '--' + args.state]
if args.compact:
    info['SweeperPreviewArguments'].append('--compact')
if args.english:
    info['SweeperPreviewArguments'].append('--english')
if args.light:
    info['SweeperPreviewArguments'].append('--light')
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump(info, file)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
