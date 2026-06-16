#!/usr/bin/env bash
# =============================================================================
#  patch-kong-rpm.sh
#  Apply kong/init.lua set_current_peer fix to a Kong .rpm package
#
#  Fix: lua-resty-core 0.1.33rc2 (OpenResty 1.29.2.3) changed set_current_peer
#  API — argument #3 is now a string (SNI host), NOT a table. Kong 3.9.x still
#  passes pool_opts table as arg #3 (old Kong-patched API), causing:
#    "bad argument #3 to 'set_current_peer' (string expected, got table)"
#
#  This is the RPM twin of patch-kong-deb.sh — SAME fix, SAME verify logic.
#
#  Unlike a .deb (a plain `ar` archive you can swap a member in), an .rpm has a
#  signed binary lead/header plus a CPIO payload, so it cannot be repacked by
#  hand. We therefore rebuild the package with `rpmrebuild`, which regenerates a
#  valid .rpm from the installed package while preserving its metadata, file
#  attributes and scriptlets — only the modified init.lua content changes.
#
#  RPM tooling (rpm2cpio + rpmrebuild + rpmbuild) is Linux-only and absent on
#  macOS. When it is missing this script re-execs itself inside a Fedora Docker
#  container (matching how this project already builds RPMs), so the SAME run
#  works on macOS and Linux alike.
#
#  Usage:
#    ./patch-kong-rpm.sh <input.rpm> [output.rpm]
#    ./patch-kong-rpm.sh output/          # patch all .rpm in a directory
#
#  Env:
#    RPM_HELPER_IMAGE=fedora:latest   # override the Docker helper image
#    DEBUG=1                          # print extra diagnostics
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${CYAN}[patch]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
# DEBUG=1 ./patch-kong-rpm.sh ...  → print extra diagnostics
dbg()  { [ "${DEBUG:-0}" = "1" ] && echo -e "${BLUE}[debug]${NC} $*" || true; }

INIT_LUA_PATH="usr/local/share/lua/5.1/kong/init.lua"
INIT_LUA_ABS="/${INIT_LUA_PATH}"
OLD_PATTERN='set_current_peer(balancer_data_ip, balancer_data_port, pool_opts)'
NEW_PATTERN='set_current_peer(balancer_data_ip, balancer_data_port)'

RPM_HELPER_IMAGE="${RPM_HELPER_IMAGE:-fedora:latest}"

# ── do we have the Linux RPM toolchain to patch natively? ─────────────────────
have_rpm_tools() {
  command -v rpm2cpio  &>/dev/null && \
  command -v rpmrebuild &>/dev/null && \
  command -v rpmbuild  &>/dev/null && \
  command -v cpio      &>/dev/null
}

# ── verify a single extracted/installed init.lua ──────────────────────────────
# (identical contract to patch-kong-deb.sh)
# Returns 0 if patched correctly (new pattern present, old pattern absent).
verify_init_file() {
  local FILE="$1" LABEL="${2:-init.lua}"
  local OLD_HITS NEW_HITS
  OLD_HITS=$(grep -cF "${OLD_PATTERN}" "${FILE}" || true)
  NEW_HITS=$(grep -cF "${NEW_PATTERN}" "${FILE}" || true)
  dbg "${LABEL}: old-pattern matches=${OLD_HITS}  new-pattern matches=${NEW_HITS}"
  if [ "${OLD_HITS}" -gt 0 ]; then
    warn "${LABEL}: old pattern STILL present (${OLD_HITS} occurrence(s)) — patch incomplete"
    return 1
  fi
  if [ "${NEW_HITS}" -lt 1 ]; then
    warn "${LABEL}: patched pattern NOT found — fix missing"
    return 1
  fi
  return 0
}

# ── apply the in-place fix (same portable python replace as the .deb script) ──
apply_fix() {
  local INIT_FILE="$1"
  dbg "Before patch — matching line(s):"
  dbg "$(grep -nF "${OLD_PATTERN}" "${INIT_FILE}" || true)"
  local PATCH_RESULT
  PATCH_RESULT=$(python3 - "${INIT_FILE}" "${OLD_PATTERN}" "${NEW_PATTERN}" << 'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
# locate the line being changed (1-based) before we rewrite the file
total = text.count(old)
if total:
    idx = text.find(old)
    lineno = text.count("\n", 0, idx) + 1
    open(path, 'w').write(text.replace(old, new, 1))
    print(f"line {lineno}: replaced 1 of {total} occurrence(s)")
    print(f"  - {old}")
    print(f"  + {new}")
elif new in text:
    print("already patched — no occurrences of old pattern (no-op)")
else:
    # neither pattern present — different Kong version; let post-checks catch it
    print("WARNING: neither old nor new pattern found in init.lua")
PYEOF
)
  dbg "Patch result:"
  dbg "${PATCH_RESULT}"
  dbg "After patch — matching line(s):"
  dbg "$(grep -nF "${NEW_PATTERN}" "${INIT_FILE}" || true)"
}

# ── extract just init.lua from an .rpm payload (for verification) ──────────────
rpm_extract_init() {
  local RPM="$1" DEST="$2"
  local RPM_ABS; RPM_ABS="$(cd "$(dirname "${RPM}")" && pwd)/$(basename "${RPM}")"
  mkdir -p "${DEST}"
  # rpm2cpio emits payload paths as ./usr/...  → cpio recreates them under DEST
  rpm2cpio "${RPM_ABS}" | ( cd "${DEST}" && cpio -idmu --quiet 2>/dev/null ) || true
}

# ── re-extract output .rpm and confirm the fix landed in the packaged file ────
verify_rpm() {
  local RPM="$1"
  local VDIR; VDIR=$(mktemp -d)
  dbg "Re-extracting ${RPM} for verification → ${VDIR}"
  rpm_extract_init "${RPM}" "${VDIR}"
  local VFILE="${VDIR}/${INIT_LUA_PATH}"
  if [ ! -f "${VFILE}" ]; then
    warn "verification: ${INIT_LUA_PATH} missing from repacked .rpm"
    rm -rf "${VDIR}"; return 1
  fi
  if verify_init_file "${VFILE}" "packaged init.lua"; then
    ok "Verified: $(basename "${RPM}") contains the fix and no stale pattern"
    rm -rf "${VDIR}"; return 0
  fi
  rm -rf "${VDIR}"; return 1
}

# ── native (Linux/in-container) patch of a single .rpm ────────────────────────
patch_rpm_native() {
  local INPUT_RPM="$1"
  local OUTPUT_RPM="${2:-$1}"

  [ -f "${INPUT_RPM}" ] || err "File not found: ${INPUT_RPM}"
  local INPUT_ABS;  INPUT_ABS="$(cd "$(dirname "${INPUT_RPM}")"  && pwd)/$(basename "${INPUT_RPM}")"
  # resolve output dir up front (may not exist yet → default to input's dir)
  local OUT_DIR; OUT_DIR="$(cd "$(dirname "${OUTPUT_RPM}")" 2>/dev/null && pwd || true)"
  [ -n "${OUT_DIR}" ] || OUT_DIR="$(dirname "${INPUT_ABS}")"
  local OUTPUT_ABS; OUTPUT_ABS="${OUT_DIR}/$(basename "${OUTPUT_RPM}")"

  # original package identity (preserved through rpmrebuild)
  local NAME ARCH
  NAME=$(rpm -qp --qf '%{NAME}' "${INPUT_ABS}" 2>/dev/null) || err "Not a valid .rpm: ${INPUT_RPM}"
  ARCH=$(rpm -qp --qf '%{ARCH}' "${INPUT_ABS}" 2>/dev/null)
  dbg "Package: ${NAME}  arch=${ARCH}"

  log "Installing ${NAME} into helper root (files only) ..."
  # Wipe any prior copy so directory-mode (e.g. amd64 then arm64) stays clean.
  rpm -e --nodeps --noscripts --allmatches "${NAME}" 2>/dev/null || true
  # --noscripts: skip Kong's pre/post (useradd etc.) — we only need files on disk
  # --ignorearch: lets an aarch64 .rpm install on an x86_64 helper and vice-versa
  rpm -Uvh --force --nodeps --noscripts --ignorearch --replacepkgs --replacefiles \
      "${INPUT_ABS}" >/dev/null 2>&1 \
    || err "rpm install failed for ${INPUT_RPM}"

  local INIT_FILE="${INIT_LUA_ABS}"
  [ -f "${INIT_FILE}" ] || err "${INIT_LUA_PATH} not found after installing ${INPUT_RPM}"
  dbg "Installed init.lua: ${INIT_FILE} ($(wc -l < "${INIT_FILE}") lines)"

  # Always apply the fix — idempotent: a no-op if already patched.
  log "Applying fix: remove pool_opts from set_current_peer ..."
  apply_fix "${INIT_FILE}"
  verify_init_file "${INIT_FILE}" "patched init.lua (pre-repack)" \
    || err "Patch verification failed for $(basename "${INPUT_RPM}") (pattern not found — different Kong version?)"
  ok "Fix applied"

  log "Repacking with rpmrebuild: $(basename "${OUTPUT_ABS}") ..."
  local TOPDIR; TOPDIR=$(mktemp -d)
  # rpmrebuild reads the now-modified file from disk + metadata from the rpmdb
  # and emits a fresh, valid .rpm under ${TOPDIR}/<arch>/.
  #   --notest-install: skip rpmrebuild's post-build trial install. It would
  #     fail in this slim helper because Kong's runtime deps (pcre/perl/zlib)
  #     aren't present — irrelevant to producing a correct package.
  rpmrebuild --batch --keep-perm --notest-install -d "${TOPDIR}" "${NAME}" >/dev/null 2>&1 \
    || err "rpmrebuild failed for ${NAME}"

  local BUILT; BUILT=$(find "${TOPDIR}" -type f -name '*.rpm' 2>/dev/null | head -1)
  [ -n "${BUILT}" ] || err "rpmrebuild produced no .rpm for ${NAME}"
  dbg "rpmrebuild output: ${BUILT}"

  mkdir -p "${OUT_DIR}"
  cp -f "${BUILT}" "${OUTPUT_ABS}"
  rm -rf "${TOPDIR}"
  ok "Done: ${OUTPUT_ABS}  ($(du -sh "${OUTPUT_ABS}" | cut -f1))"

  # re-open the produced .rpm and prove the fix is actually inside it
  log "Verifying packaged result ..."
  verify_rpm "${OUTPUT_ABS}" \
    || err "Post-repack verification FAILED — ${OUTPUT_ABS} does not contain the fix"
}

# ── dispatch: run natively if tooling exists, else re-exec inside Docker ───────
run_native() {
  local INPUT="$1"
  if [ -d "${INPUT}" ]; then
    local RPMS=()
    while IFS= read -r f; do RPMS+=("$f"); done < <(ls "${INPUT}"/*.rpm 2>/dev/null)
    [ "${#RPMS[@]}" -gt 0 ] || err "No .rpm files found in: ${INPUT}"
    log "Directory mode — ${#RPMS[@]} file(s) found"
    for RPM in "${RPMS[@]}"; do patch_rpm_native "${RPM}"; done
  else
    patch_rpm_native "${INPUT}" "${2:-${INPUT}}"
  fi
}

# ── pick a Docker --platform from an .rpm's NVRA filename (name-…-rel.ARCH.rpm)
# rpmrebuild runs `setarch <arch> rpmbuild`, which only works when the container
# kernel matches the package arch — so the helper MUST run on the rpm's platform
# (Docker provides the cross-arch emulation). Echoes "" for noarch/unknown.
rpm_platform_for() {
  local arch; arch="$(basename "$1")"; arch="${arch%.rpm}"; arch="${arch##*.}"
  case "${arch}" in
    amd64|x86_64)  echo "linux/amd64" ;;
    arm64|aarch64) echo "linux/arm64" ;;
    *)             echo "" ;;
  esac
}

# ── patch ONE .rpm inside a correctly-platformed helper container ─────────────
docker_patch_one() {
  local IN="$1" OUT="${2:-$1}"
  local SCRIPT_ABS; SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

  # bind-mount each path's location at the SAME absolute path in the container,
  # so inputs/outputs anywhere on disk (not just under $PWD) are visible.
  local MOUNTS=() ARGS=() a abs host
  for a in "${IN}" "${OUT}"; do
    if [ -e "${a}" ]; then
      abs="$(cd "$(dirname "${a}")" && pwd)/$(basename "${a}")"; host="$(dirname "${abs}")"
    else
      abs="$(cd "$(dirname "${a}")" 2>/dev/null && pwd || echo "${PWD}")/$(basename "${a}")"
      host="$(dirname "${abs}")"
    fi
    MOUNTS+=(-v "${host}:${host}")
    ARGS+=("${abs}")
  done

  local PLATFORM; PLATFORM="$(rpm_platform_for "${IN}")"
  local PLAT_ARGS=()
  if [ -n "${PLATFORM}" ]; then
    PLAT_ARGS=(--platform "${PLATFORM}")
    log "Patching $(basename "${IN}") via ${RPM_HELPER_IMAGE} (${PLATFORM}) ..."
  else
    warn "Could not infer arch from $(basename "${IN}") — using host default platform"
  fi
  dbg "Container mounts: ${MOUNTS[*]}"
  dbg "Container args:   ${ARGS[*]}"

  docker run --rm \
    "${PLAT_ARGS[@]}" \
    "${MOUNTS[@]}" \
    -v "${SCRIPT_ABS}":/patch-kong-rpm.sh:ro \
    -e IN_RPM_CONTAINER=1 -e DEBUG="${DEBUG:-0}" \
    "${RPM_HELPER_IMAGE}" \
    bash -c 'set -e
      if ! command -v rpmrebuild >/dev/null 2>&1; then
        echo "[patch] installing rpm tooling in helper container ..."
        dnf -y -q install rpm-build rpmrebuild cpio python3 findutils >/dev/null 2>&1
      fi
      exec bash /patch-kong-rpm.sh "$@"' _ "${ARGS[@]}"
}

run_in_docker() {
  command -v docker &>/dev/null \
    || err "No RPM tooling (rpm2cpio/rpmrebuild) and no docker found. Install one of them."
  warn "Host lacks RPM tooling — delegating to ${RPM_HELPER_IMAGE} container(s) ..."

  local INPUT="$1"
  if [ -d "${INPUT}" ]; then
    local RPMS=()
    while IFS= read -r f; do RPMS+=("$f"); done < <(ls "${INPUT}"/*.rpm 2>/dev/null)
    [ "${#RPMS[@]}" -gt 0 ] || err "No .rpm files found in: ${INPUT}"
    log "Directory mode — ${#RPMS[@]} file(s) found"
    # one container per file so each runs on its own matching platform
    for RPM in "${RPMS[@]}"; do docker_patch_one "${RPM}"; done
  else
    docker_patch_one "${INPUT}" "${2:-${INPUT}}"
  fi
}

# ── entry point ───────────────────────────────────────────────────────────────
[ $# -ge 1 ] || err "Usage: $0 <file.rpm | directory/> [output.rpm]"

if [ "${IN_RPM_CONTAINER:-0}" = "1" ] || have_rpm_tools; then
  run_native "$@"
else
  run_in_docker "$@"
fi
