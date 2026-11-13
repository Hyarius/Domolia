"""Install Domolia's branded launcher icon into Flutter's generated Android project.

Flutter creates Android resource folders in CI; copying the logo after
`flutter create` keeps the launcher icon consistent with the in-app emblem.
No additional Python dependencies are needed.
"""

from pathlib import Path
from shutil import copyfile

source = Path("assets/images/domolia_emblem.png")
resources = Path("android/app/src/main/res")

if not source.is_file() or source.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("Icône Domolia PNG manquante ou invalide")

densities = ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")
for density in densities:
    destination = resources / f"mipmap-{density}" / "ic_launcher.png"
    if not destination.is_file():
        raise SystemExit(f"Ressource Android introuvable : {destination}")
    copyfile(source, destination)
    print(f"Domolia launcher icon: {destination}")
