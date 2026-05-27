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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[patch]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

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
    (cd "${AR_DIR}" && ar x "${OLDPWD}/${DEB}" 2>/dev/null || ar x "${DEB}")
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
    case "${EXT}" in
      xz)  tar -cJf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      gz)  tar -czf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      zst) tar --zstd -cf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
      bz2) tar -cjf "${NEW_DATA}" -C "${SRC}" \
             $(cd "${SRC}" && ls | grep -v '\.ar_dir') ;;
    esac

    # reassemble: debian-binary + control.tar.* + data.tar.*
    local CTRL; CTRL=$(ls "${AR_DIR}"/control.tar.* 2>/dev/null | head -1)
    (cd "${AR_DIR}" && ar rc "$(basename "${OUT}")" \
      debian-binary \
      "$(basename "${CTRL}")" \
      "$(basename "${NEW_DATA}")")
    mv "${AR_DIR}/$(basename "${OUT}")" "${OUT}"
    rm -rf "${AR_DIR}"
  fi
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

  if grep -qF "${OLD_PATTERN}" "${INIT_FILE}"; then
    log "Applying fix: remove pool_opts from set_current_peer ..."
    # use python for portable in-place replace (macOS sed needs -i '' syntax)
    python3 - "${INIT_FILE}" "${OLD_PATTERN}" "${NEW_PATTERN}" << 'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
assert old in text, f"Pattern not found: {old}"
open(path, 'w').write(text.replace(old, new, 1))
PYEOF
    ok "Fix applied"
  elif grep -qF "${NEW_PATTERN}" "${INIT_FILE}"; then
    ok "Already patched — skipping: $(basename "${INPUT_DEB}")"
    trap - EXIT; rm -rf "${WORKDIR}"; return 0
  else
    warn "Pattern not found in kong/init.lua (different Kong version?)"
    trap - EXIT; rm -rf "${WORKDIR}"; return 1
  fi

  log "Repacking: $(basename "${OUTPUT_DEB}") ..."
  deb_repack "${WORKDIR}" "${OUTPUT_DEB}"
  ok "Done: ${OUTPUT_DEB}  ($(du -sh "${OUTPUT_DEB}" | cut -f1))"

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
