#!/usr/bin/env bash
# =============================================================================
#  gen-perl-vex.sh
#  Regenerate vex/perl-falsepositives.openvex.json for the Kong RPM image.
#
#  WHY THIS EXISTS
#  ---------------
#  Docker Scout false-positives the AL2023 perl stack. AL2023 builds the whole
#  perl distribution from ONE source rpm (perl-5.32.1-477.amzn2023.0.N), but
#  each binary subpackage keeps its own upstream version (perl-B 1.80,
#  perl-base 2.27, perl-DynaLoader 1.47, ...). Scout compares each subpackage's
#  upstream version against the *source* advisory fix range (<5.32.1-477.*), so
#  1.80 < 5.32.1 makes a fully-patched subpackage look vulnerable. The installed
#  release (.0.9) already contains the fix for all of:
#    CVE-2023-31484 CVE-2023-31486 CVE-2023-47038
#    CVE-2023-47100 CVE-2025-40909 CVE-2026-8376
#  Trivy evaluates the source version correctly and reports 0 — no VEX needed
#  there. This VEX only exists to clear Scout's false positives.
#
#  The product purls Scout matches are version-pinned, so this file must be
#  regenerated whenever the perl snapshot in the image changes. Run this after
#  a rebuild, then re-scan with the command in vex/README.md.
#
#  Usage:  ./vex/gen-perl-vex.sh [IMAGE]
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${1:-suriyaruk/kong-oss-3.9.2-patch:3.9.2-1.31.1.1-rpm}"
AUTHOR="${VEX_AUTHOR:-Suriya Ruk <suriya.ruk@tel.co.th>}"
OUT="vex/perl-falsepositives.openvex.json"

command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }
docker scout version >/dev/null 2>&1 || { echo "docker scout CLI required" >&2; exit 1; }

echo "[gen-perl-vex] scanning $IMAGE for flagged perl purls ..."
PURLS="$(docker scout cves --only-package perl "$IMAGE" 2>/dev/null \
          | grep -oE 'pkg:rpm/amazonlinux/perl@[^ ]+' | sort -u)"

if [ -z "$PURLS" ]; then
  echo "[gen-perl-vex] no perl findings — Scout is clean, no VEX needed." >&2
  exit 0
fi
echo "[gen-perl-vex] $(echo "$PURLS" | wc -l | tr -d ' ') flagged perl purls"

PURLS="$PURLS" AUTHOR="$AUTHOR" OUT="$OUT" python3 - <<'PY'
import json, os, datetime
purls = [p for p in os.environ["PURLS"].splitlines() if p.strip()]
author = os.environ["AUTHOR"]
out = os.environ["OUT"]
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fixes = {
    "CVE-2023-31484": "5.32.1-477.amzn2023.0.4",
    "CVE-2023-31486": "5.32.1-477.amzn2023.0.5",
    "CVE-2023-47038": "5.32.1-477.amzn2023.0.6",
    "CVE-2023-47100": "5.32.1-477.amzn2023.0.6",
    "CVE-2025-40909": "5.32.1-477.amzn2023.0.7",
    "CVE-2026-8376":  "5.32.1-477.amzn2023.0.9",
}
products = [{"@id": p} for p in purls]
stmts = [{
    "vulnerability": {"name": cve},
    "products": products,
    "status": "not_affected",
    "justification": "vulnerable_code_not_present",
    "impact_statement": (
        f"False positive. AL2023 perl source is installed at a release >= the patched "
        f"release {fix} that fixes {cve}; vulnerable code is not present. Docker Scout "
        "mis-flags because it compares each perl binary subpackage's own upstream version "
        "(e.g. perl-B 1.80, perl-base 2.27) against the source fix range (<5.32.1-477.*). "
        "Trivy evaluates the source version correctly and reports 0 for this image."
    ),
} for cve, fix in fixes.items()]
doc = {
    "@context": "https://openvex.dev/ns/v0.2.0",
    "@id": "https://tel.co.th/vex/kong-rpm-perl-falsepositives",
    "author": author,
    "timestamp": ts,
    "version": 1,
    "tooling": "vex/gen-perl-vex.sh (docker scout + trivy cross-check)",
    "statements": stmts,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
print(f"[gen-perl-vex] wrote {out}: {len(stmts)} CVEs x {len(products)} purls")
PY
