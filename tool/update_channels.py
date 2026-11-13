"""Release-channel naming shared by the Flutter build and the metadata generator."""
import hashlib
import os
import re


def channel_for_ref(ref: str) -> tuple[str, str]:
    if ref == "refs/heads/main":
        return "dev-latest", "Domolia-dev.apk"
    if ref.startswith("refs/heads/"):
        branch = ref.removeprefix("refs/heads/")
        slug = re.sub(r"[^a-z0-9-]+", "-", branch.lower()).strip("-")[:32]
        digest = hashlib.sha256(branch.encode()).hexdigest()[:10]
        return f"preview-{slug or 'branch'}-{digest}", "Domolia-preview.apk"
    if ref.startswith("refs/tags/v"):
        return ref.removeprefix("refs/tags/"), "Domolia.apk"
    raise ValueError(f"Unsupported release ref: {ref}")


if __name__ == "__main__":
    print(channel_for_ref(os.environ["GITHUB_REF"])[0])
