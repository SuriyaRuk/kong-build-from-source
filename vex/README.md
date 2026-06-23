# VEX — perl false positives (Docker Scout)

`perl-falsepositives.openvex.json` is an [OpenVEX](https://openvex.dev) document
that clears six **false-positive** perl CVEs Docker Scout reports against the
Kong RPM image (`Dockerfile.rpm`, amazonlinux:2023):

| CVE | Severity | AL2023 fix release | Installed |
|-----|----------|--------------------|-----------|
| CVE-2023-31484 | HIGH | `5.32.1-477.amzn2023.0.4` | `…0.9` ✅ |
| CVE-2023-31486 | HIGH | `5.32.1-477.amzn2023.0.5` | `…0.9` ✅ |
| CVE-2023-47038 | MEDIUM | `5.32.1-477.amzn2023.0.6` | `…0.9` ✅ |
| CVE-2023-47100 | MEDIUM | `5.32.1-477.amzn2023.0.6` | `…0.9` ✅ |
| CVE-2025-40909 | MEDIUM | `5.32.1-477.amzn2023.0.7` | `…0.9` ✅ |
| CVE-2026-8376  | MEDIUM | `5.32.1-477.amzn2023.0.9` | `…0.9` ✅ |

## Why these are false positives

AL2023 builds the entire perl distribution from one source rpm
(`perl-5.32.1-477.amzn2023.0.9`). Each binary subpackage keeps its own upstream
version (`perl-B` 1.80, `perl-base` 2.27, `perl-DynaLoader` 1.47, …) but shares
the release `477.amzn2023.0.9`. Docker Scout compares each subpackage's upstream
version against the **source** advisory fix range (`<5.32.1-477.amzn2023.0.x`),
so `1.80 < 5.32.1` makes an already-patched subpackage look vulnerable. The
installed release `.0.9` is at or above every fix above, so the vulnerable code
is **not present**.

Proof it's a scanner artifact: Scout does **not** flag the perl subpackages that
happen to be versioned `>= 5.32.1` (`perl-libs`/`perl-interpreter` 5.32.1,
`perl-AutoLoader` 5.74). And **Trivy reports 0** for this image — it evaluates
the perl source version correctly, so no `.trivyignore` is needed there.

> perl cannot simply be removed: openresty's `resty` CLI is a Perl script
> (`#!/usr/bin/env perl`) and `kong` runs through it, so perl is required by the
> entrypoint and HEALTHCHECK.

## Scan with the VEX applied

```bash
docker scout cves \
  --vex-location ./vex \
  --vex-author '<suriya.ruk@tel.co.th>' \
  suriyaruk/kong-oss-3.9.2-patch:3.9.2-1.31.1.1-rpm
# => ✓ No vulnerable package detected
```

`--vex-author` is required because Scout only trusts `<.*@docker.com>` authors by
default.

## Regenerating (after a rebuild)

The product purls are pinned to the perl snapshot in the image. After any
rebuild that changes the perl version, regenerate:

```bash
./vex/gen-perl-vex.sh [IMAGE]
```

If Scout reports no perl findings, the script exits without writing a file — the
VEX is no longer needed.
