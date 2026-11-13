"""Create public release metadata by inspecting the *built APK*, not source defaults."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ref = os.environ["GITHUB_REF"]
run = int(os.environ["GITHUB_RUN_NUMBER"])
if ref == "refs/heads/main":
    channel, asset = "dev-latest", "Domolia-dev.apk"
elif ref.startswith("refs/heads/"):
    branch = ref.removeprefix("refs/heads/")
    slug = re.sub(r"[^a-z0-9-]+", "-", branch.lower()).strip("-")[:32]
    digest = hashlib.sha256(branch.encode()).hexdigest()[:10]
    channel, asset = f"preview-{slug or 'branch'}-{digest}", "Domolia-preview.apk"
elif ref.startswith("refs/tags/v"):
    channel, asset = ref.removeprefix("refs/tags/"), "Domolia.apk"
else:
    raise SystemExit(f"No published release for {ref}")

apk = Path("dist") / asset
if not apk.is_file():
    raise SystemExit(f"Missing {apk}")

sdk = Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", "")))
binaries = list((sdk / "build-tools").glob("*/aapt"))
if not binaries:
    raise SystemExit("Android SDK aapt not found")
aapt = sorted(binaries, key=lambda p: [int(v) for v in re.findall(r"\d+", p.parent.name)])[-1]
description = subprocess.check_output([str(aapt), "dump", "badging", str(apk)], text=True)
match = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", description, re.M)
if not match:
    raise SystemExit("Cannot read versionCode/applicationId from built APK")
application_id, code, version = match.groups()
if application_id != "fr.domolia.domolia" or int(code) != run:
    raise SystemExit(f"Wrong package/version in APK: {application_id}, {code}, expected {run}")

digest = hashlib.sha256()
with apk.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)

payload = {
    "versionName": version,
    "versionCode": int(code),
    "channel": channel,
    "apkName": asset,
    "sha256": digest.hexdigest(),
    "applicationId": application_id,
}
Path("dist/Domolia-update.json").write_text(
    json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
)
print(json.dumps(payload, indent=2))
