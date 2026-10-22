"""Build the installable Workshop folder, release ZIP, and SHA-256 checksum."""
from pathlib import Path
import hashlib
import re
import shutil
import zipfile

source = Path(__file__).resolve().parents[1]
info = (source / "modinfo.lua").read_text(encoding="utf-8")
version = re.search(r'version\s*=\s*"([^"]+)"', info).group(1)
assert re.search(r"^forcemanifest\s*=\s*false\s*$", info, re.M), "Loose Workshop packages require forcemanifest=false"
dist = source / "dist"
payload = dist / source.name
files = [source / name for name in ("modinfo.lua", "modmain.lua", "README.md", "CHANGELOG.md")]
files += sorted((source / "scripts").rglob("*.lua"))
files += [source / "assets/workshop-preview.jpg"]
assert all(file.is_file() for file in files), "Release input missing"
assert 0 < (source / "assets/workshop-preview.jpg").stat().st_size < 1024 * 1024
relative_files = {file.relative_to(source) for file in files}
if payload.exists():
    unexpected = {file.relative_to(payload) for file in payload.rglob("*") if file.is_file()} - relative_files
    assert not unexpected, f"Unexpected files in release folder; review before continuing: {unexpected}"
for file in files:
    target = payload / file.relative_to(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, target)
    assert target.read_bytes() == file.read_bytes()
archive = dist / f"{source.name}_v{version}.zip"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
    for file in files:
        package.write(file, f"{source.name}/" + file.relative_to(source).as_posix())
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None
    assert len(package.namelist()) == len(files)
    for file in files:
        assert package.read(f"{source.name}/" + file.relative_to(source).as_posix()) == file.read_bytes()
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix(".zip.sha256").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
print(f"WORKSHOP_FOLDER {payload}")
print(f"RELEASE_ZIP {archive}")
print(f"FILES {len(files)} SHA256 {digest}")
