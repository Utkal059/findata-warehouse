#!/usr/bin/env python3
"""Fetch the PKDD'99 Financial (Berka) dataset into data/raw/.

Python is used ONLY to download and unzip the source files. No parsing,
cleaning or transformation happens here - every rule lives in PL/SQL.

Usage:
    python3 scripts/download_data.py            # download + verify
    python3 scripts/download_data.py --force    # re-download even if present
"""
import argparse
import hashlib
import io
import pathlib
import sys
import urllib.error
import urllib.request
import zipfile

FILES = [
    "account.asc", "card.asc", "client.asc", "disp.asc",
    "district.asc", "loan.asc", "order.asc", "trans.asc",
]

# Original challenge archive hosted by the dataset author (frequently offline).
ZIP_URLS = [
    "https://sorry.vse.cz/~berka/challenge/pkdd1999/data_berka.zip",
    "http://lisp.vse.cz/pkdd99/DATA/data_berka.zip",
]

# Public copies of the original .asc files, pinned to an exact commit so the
# bytes can never change underneath us. SHA-256 below is checked either way.
MIRRORS = [
    "https://raw.githubusercontent.com/ekapope/Banking-Data-Analysis-Reveals-Non-Performing-Customers/"
    "37a0fbae883ca9ce0d30c9cd129953d33840bf53/data/data_berka/{name}",
    "https://raw.githubusercontent.com/inderrana/Financial-Datamart-Analytical-Base-Table/"
    "d89fc8a0b270936a1baa26a291d03a48986354cb/data/raw/data_berka/{name}",
]

EXPECTED_SHA256 = {
    "account.asc":  "215f4bfcb2520ab8d41154f22b5b294050cc142bb0c7362b05ab6da4742432eb",
    "card.asc":     "a4531f8d48f21ed54ba994701547170eac156260fe5c781ec8e2063e1976ba25",
    "client.asc":   "2b2f5253f21418c4e1366051a988d5e184dd18d3f2159d28dd9fd086819c15e9",
    "disp.asc":     "77e08c0988473998abe8b1802446c7c1c1eccb76841c34295baa9b9fdc98d4cc",
    "district.asc": "d5422aa7326fde860b7285adee5e454d914f70900b66c6411528b2b8893ba0ce",
    "loan.asc":     "0cf9fbe7ec2ebb7a2547243d9af5f63f8c064e8f9982917cc000292bcee1fa1e",
    "order.asc":    "c1d909d5d8a56ce679646c3f56544053ecec4d9688e995758e7a58532e811d00",
    "trans.asc":    "111c70dc6626411d1d6547245c318b507e0c2892093f092d579468b71619bd3e",
}

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "data" / "raw"


def fetch(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "findata-warehouse/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def line_count(data):
    n = data.count(b"\n")
    if data and not data.endswith(b"\n"):
        n += 1
    return n


def try_zip():
    for url in ZIP_URLS:
        try:
            print(f"  trying archive {url}")
            blob = fetch(url)
            with zipfile.ZipFile(io.BytesIO(blob)) as zf:
                members = {pathlib.PurePath(m).name.lower(): m for m in zf.namelist()}
                if not all(f in members for f in FILES):
                    print("    archive is missing files, skipping")
                    continue
                return {f: zf.read(members[f]) for f in FILES}
        except (urllib.error.URLError, OSError, zipfile.BadZipFile) as exc:
            print(f"    unavailable: {exc}")
    return None


def try_mirror(name):
    for template in MIRRORS:
        url = template.format(name=name)
        try:
            data = fetch(url)
            exp = EXPECTED_SHA256.get(name)
            if exp and sha256(data) != exp:
                print(f"    checksum mismatch from {url}, trying next mirror")
                continue
            return data
        except (urllib.error.URLError, OSError) as exc:
            print(f"    {url} unavailable: {exc}")
    raise SystemExit(f"ERROR: could not download {name} from any source")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--force", action="store_true", help="re-download existing files")
    args = ap.parse_args()

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    missing = [f for f in FILES if args.force or not (RAW_DIR / f).exists()]

    if missing:
        print(f"Downloading {len(missing)} file(s) into {RAW_DIR}")
        from_zip = try_zip()
        for name in missing:
            data = from_zip[name] if from_zip else try_mirror(name)
            (RAW_DIR / name).write_bytes(data)
            print(f"  saved {name} ({len(data):,} bytes)")
    else:
        print("All files already present (use --force to re-download)")

    print()
    print(f"{'file':<14}{'bytes':>12}{'data_rows':>11}  sha256")
    failed = False
    for name in FILES:
        data = (RAW_DIR / name).read_bytes()
        digest = sha256(data)
        exp = EXPECTED_SHA256.get(name)
        flag = ""
        if exp and digest != exp:
            flag, failed = "  <-- CHECKSUM MISMATCH", True
        print(f"{name:<14}{len(data):>12,}{line_count(data) - 1:>11,}  {digest}{flag}")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
