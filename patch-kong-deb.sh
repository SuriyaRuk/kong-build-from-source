#!/usr/bin/env bash
# =============================================================================
#  patch-kong-deb.sh
#  Apply kong/init.lua set_current_peer fix to a Kong .deb package
#
#  Fix: lua-resty-core 0.1.33rc2 (OpenResty 1.29.2.3) changed set_current_peer
#  API — argument #3 is now a string (SNI host), NOT a table. Kong 3.9.1 still
#  passes pool_opts table as arg #3 (old Kong-patched API), causing:
#    "bad argument #3 to 'set_current_peer' (string expected, got table)"
#
#  Works on: Linux (dpkg-deb) and macOS (ar + tar fallback)
#  macOS deps: ar, tar, xz  — all bundled with Xcode Command Line Tools
#
#  Usage:
#    ./patch-kong-deb.sh <input.deb> [output.deb]
#    ./patch-kong-deb.sh output/          # patch all .deb in a directory
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${CYAN}[patch]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }
# DEBUG=1 ./patch-kong-deb.sh ...  → print extra diagnostics
dbg()  { [ "${DEBUG:-0}" = "1" ] && echo -e "${BLUE}[debug]${NC} $*" || true; }

INIT_LUA_PATH="usr/local/share/lua/5.1/kong/init.lua"
OLD_PATTERN='set_current_peer(balancer_data_ip, balancer_data_port, pool_opts)'
NEW_PATTERN='set_current_peer(balancer_data_ip, balancer_data_port)'

# ── extract .deb → directory ──────────────────────────────────────────────────
deb_extract() {
  local DEB="$1" DEST="$2"
  if command -v dpkg-deb &>/dev/null; then
    dpkg-deb -R "${DEB}" "${DEST}/"
  else
    # portable fallback: .deb = ar archive containing data.tar.*
    local AR_DIR; AR_DIR=$(mktemp -d)
    local DEB_ABS; DEB_ABS="$(cd "$(dirname "${DEB}")" && pwd)/$(basename "${DEB}")"
    # NOTE: macOS BSD `ar` cannot extract .deb built with GNU ar — GNU appends a
    # name-terminator '/' to members (e.g. data.tar.gz/) which BSD ar treats as a
    # literal path and fails ("No such file or directory"), extracting nothing.
    # libarchive `tar` reads the ar container directly and handles both formats.
    if tar -xf "${DEB_ABS}" -C "${AR_DIR}" 2>/dev/null; then
      :
    else
      # last-resort: BSD/GNU ar (only reaches here if tar lacks ar support)
      (cd "${AR_DIR}" && ar x "${DEB_ABS}")
    fi
    local DATA_TAR; DATA_TAR=$(ls "${AR_DIR}"/data.tar.* 2>/dev/null | head -1)
    [ -n "${DATA_TAR}" ] || err "data.tar.* not found inside .deb"
    mkdir -p "${DEST}"
    case "${DATA_TAR}" in
      *.tar.xz)  tar -xJf "${DATA_TAR}" -C "${DEST}" ;;
      *.tar.gz)  tar -xzf "${DATA_TAR}" -C "${DEST}" ;;
      *.tar.zst) tar --zstd -xf "${DATA_TAR}" -C "${DEST}" ;;
      *.tar.bz2) tar -xjf "${DATA_TAR}" -C "${DEST}" ;;
      *)         err "Unknown data archive format: ${DATA_TAR}" ;;
    esac
    # keep ar dir for repack
    echo "${AR_DIR}" > "${DEST}/.ar_dir"
  fi
}

# ── repack directory → .deb ───────────────────────────────────────────────────
deb_repack() {
  local SRC="$1" OUT="$2"
  if command -v dpkg-deb &>/dev/null; then
    if command -v fakeroot &>/dev/null; then
      fakeroot dpkg-deb -b "${SRC}/" "${OUT}"
    else
      dpkg-deb -b "${SRC}/" "${OUT}"
    fi
  else
    # portable fallback
    local AR_DIR_FILE="${SRC}/.ar_dir"
    [ -f "${AR_DIR_FILE}" ] || err "ar_dir reference missing — cannot repack"
    local AR_DIR; AR_DIR=$(cat "${AR_DIR_FILE}")

    local DATA_TAR_ORIG; DATA_TAR_ORIG=$(ls "${AR_DIR}"/data.tar.* | head -1)
    local EXT="${DATA_TAR_ORIG##*.tar.}"
    local NEW_DATA="${AR_DIR}/data.tar.${EXT}"

    # recompress data archive
    # CRITICAL: force GNU tar format. macOS `tar` is bsdtar/libarchive, whose
    # default (restricted PAX) emits `type 'x'` extended headers for long paths
    # and metadata. dpkg-deb's minimal tar reader rejects those with:
    #   "unsupported PAX tar header type 'x'"
    # gnutar format is what real .deb data archives use; --no-mac-metadata drops
    # AppleDouble/xattr entries that would otherwise pollute the package.
    local TAR_FMT="--format=gnutar --no-mac-metadata"
    case "${EXT}" in
      xz)  tar ${TAR_FMT} -cJf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      gz)  tar ${TAR_FMT} -czf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      zst) tar ${TAR_FMT} --zstd -cf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      bz2) tar ${TAR_FMT} -cjf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
    esac

    # reassemble: debian-binary + control.tar.* + data.tar.*
    # ORDER MATTERS — debian-binary MUST be the first ar member for dpkg.
    local CTRL; CTRL=$(ls "${AR_DIR}"/control.tar.* 2>/dev/null | head -1)
    local OUT_BASE; OUT_BASE=$(basename "${OUT}")
    # Prefer libarchive tar to write the canonical GNU-format ar container
    # (what real .deb files and dpkg-deb produce). macOS BSD `ar rc` silently
    # emits a symtab-only archive that drops every member, so it is only a
    # last resort and MUST use `S` to suppress the symbol table.
    if ! (cd "${AR_DIR}" && tar -cf "${OUT_BASE}" --format=argnu \
            debian-binary "$(basename "${CTRL}")" "$(basename "${NEW_DATA}")" 2>/dev/null); then
      (cd "${AR_DIR}" && ar rcS "${OUT_BASE}" \
            debian-binary "$(basename "${CTRL}")" "$(basename "${NEW_DATA}")")
    fi
    mv "${AR_DIR}/${OUT_BASE}" "${OUT}"
    rm -rf "${AR_DIR}"
  fi
}

# ── verify a single extracted init.lua ────────────────────────────────────────
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

# ── re-extract output .deb and confirm the fix landed in the packaged file ─────
verify_deb() {
  local DEB="$1"
  local VDIR; VDIR=$(mktemp -d)
  dbg "Re-extracting ${DEB} for verification → ${VDIR}"
  deb_extract "${DEB}" "${VDIR}"
  local VFILE="${VDIR}/${INIT_LUA_PATH}"
  if [ ! -f "${VFILE}" ]; then
    warn "verification: ${INIT_LUA_PATH} missing from repacked .deb"
    rm -rf "${VDIR}"; return 1
  fi
  if verify_init_file "${VFILE}" "packaged init.lua"; then
    ok "Verified: $(basename "${DEB}") contains the fix and no stale pattern"
    rm -rf "${VDIR}"; return 0
  fi
  rm -rf "${VDIR}"; return 1
}

# ── main patch function ───────────────────────────────────────────────────────
patch_deb() {
  local INPUT_DEB="$1"
  local OUTPUT_DEB="${2:-$1}"

  [ -f "${INPUT_DEB}" ] || err "File not found: ${INPUT_DEB}"

  local WORKDIR; WORKDIR=$(mktemp -d)
  trap "rm -rf '${WORKDIR}'" EXIT

  log "Extracting: $(basename "${INPUT_DEB}") ..."
  deb_extract "${INPUT_DEB}" "${WORKDIR}"

  local INIT_FILE="${WORKDIR}/${INIT_LUA_PATH}"
  [ -f "${INIT_FILE}" ] || err "${INIT_LUA_PATH} not found inside .deb"
  dbg "Extracted init.lua: ${INIT_FILE} ($(wc -l < "${INIT_FILE}") lines)"

  # Always apply the fix — never skip. The replace is idempotent: if the file
  # is already patched (old pattern absent) it is a no-op, and every .deb is
  # still repacked + verified below.
  log "Applying fix: remove pool_opts from set_current_peer ..."
  dbg "Before patch — matching line(s):"
  dbg "$(grep -nF "${OLD_PATTERN}" "${INIT_FILE}" || true)"
  # use python for portable in-place replace (macOS sed needs -i '' syntax)
  # capture the replace result so we can report exactly what changed via dbg
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
  # confirm the result before we bother repacking; this fails loudly if the
  # .deb is a different Kong version with neither pattern present
  verify_init_file "${INIT_FILE}" "patched init.lua (pre-repack)" \
    || err "Patch verification failed for $(basename "${INPUT_DEB}") (pattern not found — different Kong version?)"
  ok "Fix applied"

  log "Repacking: $(basename "${OUTPUT_DEB}") ..."
  deb_repack "${WORKDIR}" "${OUTPUT_DEB}"
  ok "Done: ${OUTPUT_DEB}  ($(du -sh "${OUTPUT_DEB}" | cut -f1))"

  # re-open the produced .deb and prove the fix is actually inside it
  log "Verifying packaged result ..."
  verify_deb "${OUTPUT_DEB}" \
    || err "Post-repack verification FAILED — ${OUTPUT_DEB} does not contain the fix"

  trap - EXIT; rm -rf "${WORKDIR}"
}

# ── entry point ───────────────────────────────────────────────────────────────
[ $# -ge 1 ] || err "Usage: $0 <file.deb | directory/> [output.deb]"

INPUT="$1"

if [ -d "${INPUT}" ]; then
  mapfile -t DEBS < <(ls "${INPUT}"/*.deb 2>/dev/null)
  [ "${#DEBS[@]}" -gt 0 ] || err "No .deb files found in: ${INPUT}"
  log "Directory mode — ${#DEBS[@]} file(s) found"
  for DEB in "${DEBS[@]}"; do patch_deb "${DEB}"; done
else
  patch_deb "${INPUT}" "${2:-${INPUT}}"
fi
