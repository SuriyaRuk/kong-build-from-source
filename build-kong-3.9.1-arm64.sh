#!/usr/bin/env bash
# =============================================================================
#  build-kong-3.9.1-arm64.sh
#  Build Kong OSS 3.9.1 arm64 .deb using QEMU emulation
#  OpenResty: 1.29.2.3   |   Base OS: Ubuntu 20.04
#
#  Prerequisites:
#    - Docker Desktop with QEMU support (Docker Desktop on Mac includes this)
#    - Run from the build-from-source directory
#
#  Output: output/kong-3.9.1.20.04.arm64.deb
# =============================================================================
set -euo pipefail

# ─── Versions ─────────────────────────────────────────────────────────────────
KONG_VERSION="3.9.1"
KONG_TAG="3.9.1"
RESTY_VERSION="1.29.2.5"
RESTY_LUAROCKS_VERSION="3.11.1"
RESTY_OPENSSL_VERSION="3.5.6"
KONG_OPENSSL_VERSION="0"
RESTY_PCRE_VERSION="10.46"

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use separate dirs from amd64 build to avoid conflicts
BUILD_TOOLS_DIR="/tmp/kong-build-tools-391-arm64"
KONG_SOURCE_DIR="/tmp/kong-source-391-arm64"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ─── Build settings ───────────────────────────────────────────────────────────
RESTY_IMAGE_BASE="ubuntu"
RESTY_IMAGE_TAG="26.04"
PACKAGE_TYPE="deb"
# Use a different local name from amd64 build to avoid tag conflicts
DOCKER_REPOSITORY="kong-build-local-arm64"
SSL_PROVIDER="openssl"
TARGET_PLATFORM="linux/arm64"
TARGET_ARCH="arm64"

# ─── Helper ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# ─── 0. Set up QEMU for arm64 emulation (only when cross-building) ─────────────
# Do NOT run 'multiarch/qemu-user-static --reset': it wipes all binfmt_misc
# handlers and registers a qemu interpreter for the host's OWN architecture
# (e.g. 'qemu-aarch64-static as binfmt interpreter for aarch64'). On an arm64
# host that forces every native arm64 binary — including containerd's shim —
# through QEMU, which then fails with:
#   failed to start shim: fork/exec /usr/local/bin/containerd-shim-runc-v2: exec format error
# OrbStack/Docker Desktop already provide native cross-arch emulation, so arm64
# builds on an arm64 host need no QEMU registration at all.
HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  arm64|aarch64)
    log "Host is ${HOST_ARCH}; arm64 build is native — skipping QEMU registration." ;;
  *)
    log "Host is ${HOST_ARCH}; registering QEMU for arm64 emulation via tonistiigi/binfmt ..."
    # --install arm64 registers ONLY the foreign aarch64 handler and leaves the
    # host's native binfmt entry untouched.
    docker run --rm --privileged tonistiigi/binfmt --install arm64
    log "  -> QEMU arm64 registered" ;;
esac

# Force all docker commands to build for arm64
export DOCKER_DEFAULT_PLATFORM=linux/arm64
# Use legacy builder (BuildKit is disabled to match the amd64 build toolchain)
export DOCKER_BUILDKIT=0

# ─── 1. Clone / update kong-build-tools ───────────────────────────────────────
if [ ! -d "${BUILD_TOOLS_DIR}" ]; then
  log "Cloning SuriyaRuk/kong-build-tools ..."
  git clone https://github.com/SuriyaRuk/kong-build-tools.git "${BUILD_TOOLS_DIR}"
else
  log "kong-build-tools already present – pulling latest master ..."
  git -C "${BUILD_TOOLS_DIR}" checkout master
  git -C "${BUILD_TOOLS_DIR}" pull
fi

# ─── 2. Clone Kong source at tag 3.9.1 ────────────────────────────────────────
if [ ! -d "${KONG_SOURCE_DIR}" ]; then
  log "Cloning Kong at tag ${KONG_TAG} ..."
  git clone --depth=1 --branch "${KONG_TAG}" \
    https://github.com/Kong/kong.git "${KONG_SOURCE_DIR}"
else
  log "Kong source already present at ${KONG_SOURCE_DIR}"
fi

# ─── 3. Verify .requirements exists ───────────────────────────────────────────
if [ ! -f "${KONG_SOURCE_DIR}/.requirements" ]; then
  err "Kong .requirements file not found in ${KONG_SOURCE_DIR}"
fi
log "Kong .requirements:"
grep -E 'RESTY_VERSION|KONG_VERSION|RESTY_LUAROCKS|OPENSSL' \
  "${KONG_SOURCE_DIR}/.requirements" || true

# ─── 4. Patch: duplicate healthcheck in test compose file ─────────────────────
COMPOSE_FILE="${BUILD_TOOLS_DIR}/test/kong-tests-compose.yaml"
if [ -f "${COMPOSE_FILE}" ]; then
  log "Patching duplicate healthcheck in test/kong-tests-compose.yaml ..."
  python3 - "${COMPOSE_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
content = f.read_text()

BAD = (
    "    healthcheck:\n"
    '      test: ["CMD", "pg_isready", "-U", "${KONG_PG_USER:-kong}"]\n'
    "      interval: 30s\n"
    "      timeout: 30s\n"
    "      retries: 3\n"
    "    restart: on-failure\n"
    "    stdin_open: true\n"
    "    tty: true\n"
    "    healthcheck:\n"
    '      test: ["CMD", "pg_isready", "-U", "${KONG_PG_USER:-kong}"]\n'
    "      interval: 5s\n"
    "      timeout: 10s\n"
    "      retries: 10\n"
)
GOOD = (
    "    healthcheck:\n"
    '      test: ["CMD", "pg_isready", "-U", "${KONG_PG_USER:-kong}"]\n'
    "      interval: 5s\n"
    "      timeout: 10s\n"
    "      retries: 10\n"
    "    restart: on-failure\n"
    "    stdin_open: true\n"
    "    tty: true\n"
)

if BAD in content:
    f.write_text(content.replace(BAD, GOOD, 1))
    print("  -> duplicate healthcheck removed.")
else:
    print("  -> already clean, no patch needed.")
PYEOF
fi

# ─── 5. Init submodules ────────────────────────────────────────────────────────
log "Initialising submodules in kong-build-tools ..."
git -C "${BUILD_TOOLS_DIR}" submodule update --init --recursive

# ─── Patch A+B: remove syntax directive and secret mounts from Dockerfiles ────
python3 - "${BUILD_TOOLS_DIR}/dockerfiles" << 'PYEOF'
import sys, pathlib, re

ddir = pathlib.Path(sys.argv[1])
for name in ("Dockerfile.openresty", "Dockerfile.kong"):
    df = ddir / name
    if not df.exists():
        continue
    text = df.read_text()
    text = re.sub(r'^# syntax\s*=.*\n', '', text, flags=re.MULTILINE)
    text = re.sub(
        r'^(RUN) --mount=type=secret,id=github-token\s+',
        r'\1 ',
        text,
        flags=re.MULTILINE,
    )
    df.write_text(text)
    print(f"  -> Patched {name}")
PYEOF
log "Patched Dockerfiles: removed syntax directive and secret mounts"

# ─── Patch C: remove --secret flag from Makefile ──────────────────────────────
MAKEFILE="${BUILD_TOOLS_DIR}/Makefile"
if [ -f "${MAKEFILE}" ]; then
  sed -i.bak '/--secret id=github-token,src=github-token/d' "${MAKEFILE}"
  log "Patched Makefile: removed --secret lines"
fi

# ─── Patch D: strip trailing '# comment' from Kong .requirements ──────────────
REQ_FILE="${KONG_SOURCE_DIR}/.requirements"
if [ -f "${REQ_FILE}" ] && grep -qE '[[:space:]]+#' "${REQ_FILE}"; then
  log "Stripping inline '# comment' suffixes from ${REQ_FILE}"
  sed -i.bak -E 's/[[:space:]]+#.*$//' "${REQ_FILE}"
fi

# ─── Patch E: teach kong-ngx-build to download PCRE2 ─────────────────────────
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE} to support PCRE2 downloads"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

OLD = (
    '    if [ ! -z "$PCRE_VER" ]; then\n'
    '      PCRE_DOWNLOAD=$DOWNLOAD_CACHE/pcre-$PCRE_VER\n'
    '      if [ ! -d $PCRE_DOWNLOAD ]; then\n'
    '        warn "PCRE source not found, downloading..."\n'
    '        with_backoff curl -sSLO https://downloads.sourceforge.net/project/pcre/pcre/${PCRE_VER}/pcre-${PCRE_VER}.tar.gz\n'
    '        if [ ! -z ${PCRE_SHA+x} ]; then\n'
    '          echo "$PCRE_SHA pcre-${PCRE_VER}.tar.gz" | sha256sum -c -\n'
    '        else\n'
    '          notice "Downloaded: $(sha256sum "pcre-${PCRE_VER}.tar.gz")"\n'
    '        fi\n'
    '        tar -xzf pcre-${PCRE_VER}.tar.gz\n'
    '        ln -s pcre-${PCRE_VER} pcre\n'
    '      fi\n'
    '    fi\n'
)

NEW = (
    '    if [ ! -z "$PCRE_VER" ]; then\n'
    '      PCRE_DOWNLOAD=$DOWNLOAD_CACHE/pcre-$PCRE_VER\n'
    '      if [ ! -d $PCRE_DOWNLOAD ]; then\n'
    '        warn "PCRE source not found, downloading..."\n'
    '        if [[ "$PCRE_VER" =~ ^10\\. ]]; then\n'
    '          with_backoff curl -sSLO https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VER}/pcre2-${PCRE_VER}.tar.gz\n'
    '          if [ ! -z ${PCRE_SHA+x} ]; then\n'
    '            echo "$PCRE_SHA pcre2-${PCRE_VER}.tar.gz" | sha256sum -c -\n'
    '          else\n'
    '            notice "Downloaded: $(sha256sum "pcre2-${PCRE_VER}.tar.gz")"\n'
    '          fi\n'
    '          tar -xzf pcre2-${PCRE_VER}.tar.gz\n'
    '          ln -s pcre2-${PCRE_VER} pcre-${PCRE_VER}\n'
    '          ln -s pcre2-${PCRE_VER} pcre\n'
    '        else\n'
    '          with_backoff curl -sSLO https://downloads.sourceforge.net/project/pcre/pcre/${PCRE_VER}/pcre-${PCRE_VER}.tar.gz\n'
    '          if [ ! -z ${PCRE_SHA+x} ]; then\n'
    '            echo "$PCRE_SHA pcre-${PCRE_VER}.tar.gz" | sha256sum -c -\n'
    '          else\n'
    '            notice "Downloaded: $(sha256sum "pcre-${PCRE_VER}.tar.gz")"\n'
    '          fi\n'
    '          tar -xzf pcre-${PCRE_VER}.tar.gz\n'
    '          ln -s pcre-${PCRE_VER} pcre\n'
    '        fi\n'
    '      fi\n'
    '    fi\n'
)

if OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> PCRE2 branch added to kong-ngx-build")
elif 'PCRE2Project/pcre2' in text:
    print("  -> already patched, skipping")
else:
    sys.exit("  !! expected PCRE block not found — upstream layout changed")
PYEOF
fi

# ─── Patch F: fix OpenResty download URL in kong-ngx-build ───────────────────
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: fixing OpenResty download URL"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

OLD = (
    "      if [ ! -d $OPENRESTY_DOWNLOAD ]; then\n"
    "        warn \"OpenResty source not found, downloading...\"\n"
    "        with_backoff curl -fL --retry 3 --retry-delay 2 -sSLO https://github.com/Kong/lua-resty-websocket/archive/${RESTY_WEBSOCKET}.tar.gz\n"
)

NEW = (
    "      if [ ! -d $OPENRESTY_DOWNLOAD ]; then\n"
    "        warn \"OpenResty source not found, downloading...\"\n"
    "        with_backoff curl --fail -sSLO https://openresty.org/download/openresty-$OPENRESTY_VER.tar.gz\n"
)

if OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> OpenResty download URL fixed")
elif 'openresty.org/download/openresty-$OPENRESTY_VER' in text:
    print("  -> already correct, skipping")
else:
    sys.exit("  !! expected OpenResty download block not found — upstream layout changed")
PYEOF
fi

# ─── Patch G: fix lua-resty-websocket download URL ───────────────────────────
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: fixing lua-resty-websocket download URL"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

OLD = '"https://github.com/Kong/lua-resty-websocket/archive/refs/tags/${RESTY_WEBSOCKET}.tar.gz"'
NEW = '"https://github.com/Kong/lua-resty-websocket/archive/${RESTY_WEBSOCKET}.tar.gz"'

if OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> lua-resty-websocket URL fixed (removed refs/tags/)")
elif NEW in text:
    print("  -> already correct, skipping")
else:
    sys.exit("  !! expected lua-resty-websocket URL not found — upstream layout changed")
PYEOF
fi

# ─── Patch H: add disable_http2_alpn to ngx_http_lua_ssl_ctx_t ───────────────
# OpenResty 1.29.2.5 bundles ngx_lua-0.10.31rc2 (1.29.2.3 bundled 0.10.30rc2).
# kong-ngx-build applies this with `patch -p1` from the bundle dir, so the path
# inside the patch header MUST match the bundled directory name, or patch fails
# with "can't find file to patch".
PATCHES_DIR="${BUILD_TOOLS_DIR}/openresty-patches/patches/1.29.2.5"
mkdir -p "${PATCHES_DIR}"
# Drop any stale patch targeting the old ngx_lua-0.10.30rc2 dir; the kong-ngx-build
# glob would otherwise still apply it and fail.
rm -f "${PATCHES_DIR}"/ngx_lua-0.10.30rc2_*.patch
PATCH_FILE="${PATCHES_DIR}/ngx_lua-0.10.31rc2_01-add-disable-http2-alpn.patch"
log "Writing ngx_http_lua_ssl_ctx_t patch for OpenResty 1.29.2.5 (ngx_lua-0.10.31rc2) ..."
cat > "${PATCH_FILE}" << 'PATCHEOF'
--- a/ngx_lua-0.10.31rc2/src/ngx_http_lua_ssl.h
+++ b/ngx_lua-0.10.31rc2/src/ngx_http_lua_ssl.h
@@ -48,6 +48,7 @@
     unsigned                 entered_client_hello_handler:1;
     unsigned                 entered_cert_handler:1;
     unsigned                 entered_sess_fetch_handler:1;
+    unsigned                 disable_http2_alpn:1;
 #if HAVE_LUA_PROXY_SSL
     unsigned                 entered_proxy_ssl_cert_handler:1;
     unsigned                 entered_proxy_ssl_verify_handler:1;
PATCHEOF
log "  -> patch written: ${PATCH_FILE}"

# ─── NOTE: NGINX Rift CVEs (Kong discussion #14867) — NO PATCH NEEDED ────────
# CVE-2026-42945 (rewrite), 42946 (scgi/uwsgi), 40701 (OCSP resolver),
# 42934 (charset), 40460 (HTTP/3) and 42926 (proxy_v2/HTTP2).
# DO NOT add OPENRESTY_PATCHES entries to backport these — OpenResty 1.29.2.5
# ALREADY ships all of them. Verified 2026-05-26: every added line of the
# upstream fix commits 524977e / 54b7945 / d2b8d47 / 5461e8b / f79c286 /
# 5f86648 is already present in bundle/nginx-1.29.2, even though the nginx
# version string still reads "1.29.2". nginx.org lists "1.29.2" as vulnerable
# because that table tracks VANILLA nginx, not OpenResty's backported bundle.
# CVE-2026-42926 does not apply: ngx_http_proxy_v2_module was introduced in
# nginx 1.29.4 and is absent in 1.29.2.
# Adding those patches would BREAK the build: kong-ngx-build runs `patch -p1`
# WITHOUT --forward, so already-applied hunks trigger "Reversed (or previously
# applied) patch detected" -> non-zero exit -> `|| fatal`.
# (Kong's advisory also notes the default Kong config triggers none of these.)

# ─── Patch I: fix 'set -e/' typo in kong-ngx-build ───────────────────────────
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: fixing 'set -e/' typo"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

OLD = '          set -e/\n'
NEW = '          set -e\n'

if OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> 'set -e/' corrected to 'set -e'")
elif '          set -e\n' in text and '          set -e/\n' not in text:
    print("  -> already correct, skipping")
else:
    sys.exit("  !! 'set -e/' line not found — upstream layout changed")
PYEOF
fi

# ─── Patch I2: clear stale LuaRocks manifest cache in build-kong.sh ──────────
BUILD_KONG_SH="${BUILD_TOOLS_DIR}/build-kong.sh"
if [ -f "${BUILD_KONG_SH}" ]; then
  log "Patching build-kong.sh: clear LuaRocks manifest cache before install"
  python3 - "${BUILD_KONG_SH}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

MARKER = 'rm -rf /var/cache/luarocks/'
OLD = 'export LUAROCKS_CONFIG=$ROCKS_CONFIG\n'
NEW = (
    'export LUAROCKS_CONFIG=$ROCKS_CONFIG\n'
    '\n'
    '# Clear stale manifest cache from base image; forces LuaRocks to download\n'
    '# the current chunked manifest format (each chunk < 65536 Lua constants).\n'
    'rm -rf /var/cache/luarocks/\n'
    '\n'
)

if MARKER in text:
    print("  -> already patched, skipping")
elif OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> LuaRocks cache-clear added to build-kong.sh")
else:
    sys.exit("  !! 'export LUAROCKS_CONFIG' line not found — upstream layout changed")
PYEOF
fi

# ─── Patch J: pre-install Kong deps via per-author luarocks.org manifests ─────
# The global luarocks.org manifest-5.1 has grown beyond LuaJIT's 65536-constant
# limit even after clearing /var/cache/luarocks/.  Per-author manifests at
# luarocks.org/manifests/<user>/ each contain only that user's packages and stay
# well under the limit.  Install each of the 33 Kong deps individually from its
# author's manifest, then build Kong with --deps-mode none.
#
# Each install_rock MUST pass YAML_LIBDIR/YAML_INCDIR (plus the other DIR hints):
# lyaml's rockspec runs luarocks' own libyaml probe, which only searches system
# paths (/usr/lib/aarch64-linux-gnu, /lib, …).  libyaml is built into
# /tmp/build/usr/local/kong/lib earlier in the build, so without these hints the
# lyaml install fails with "Could not find library file for YAML".
BUILD_KONG_SH="${BUILD_TOOLS_DIR}/build-kong.sh"
if [ -f "${BUILD_KONG_SH}" ]; then
  # Restore pristine build-kong.sh first: a previous run may have written an
  # older install_rock block (missing the YAML dir hints) whose marker would
  # otherwise make this patch skip and leave the broken version in place.
  git -C "${BUILD_TOOLS_DIR}" checkout -- build-kong.sh 2>/dev/null || true
  log "Patching build-kong.sh: pre-install deps via per-author manifests + --deps-mode none"
  python3 - "${BUILD_KONG_SH}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

MARKER = 'install_rock '
if MARKER in text:
    print("  -> already patched, skipping")
    sys.exit(0)

OLD = (
    '  with_backoff /usr/local/bin/luarocks make kong-${ROCKSPEC_VERSION}.rockspec \\\n'
    '    CRYPTO_DIR=/usr/local/kong \\\n'
    '    OPENSSL_DIR=/usr/local/kong \\\n'
    '    YAML_LIBDIR=/tmp/build/usr/local/kong/lib \\\n'
    '    YAML_INCDIR=/tmp/yaml \\\n'
    '    EXPAT_DIR=/usr/local/kong \\\n'
    '    LIBXML2_DIR=/usr/local/kong \\\n'
    '    CFLAGS="-L/tmp/build/usr/local/kong/lib -Wl,-rpath,/usr/local/kong/lib -O2 -std=gnu99 -fPIC"\n'
)

NEW = (
    '  # Install each Kong dep via its author\'s per-user luarocks.org manifest.\n'
    '  # The global manifest-5.1 exceeds LuaJIT\'s 65536-constant limit.\n'
    '  install_rock() {\n'
    '    local author="$1" name="$2" ver="$3"\n'
    '    with_backoff /usr/local/bin/luarocks install "$name" "$ver" \\\n'
    '      --server="https://luarocks.org/manifests/$author" \\\n'
    '      --deps-mode none \\\n'
    '      CRYPTO_DIR=/usr/local/kong \\\n'
    '      OPENSSL_DIR=/usr/local/kong \\\n'
    '      YAML_LIBDIR=/tmp/build/usr/local/kong/lib \\\n'
    '      YAML_INCDIR=/tmp/yaml \\\n'
    '      EXPAT_DIR=/usr/local/kong \\\n'
    '      LIBXML2_DIR=/usr/local/kong \\\n'
    '      CFLAGS="-L/tmp/build/usr/local/kong/lib -Wl,-rpath,/usr/local/kong/lib -O2 -std=gnu99 -fPIC"\n'
    '  }\n'
    '  install_rock kikito        inspect               3.1.3\n'
    '  install_rock brunoos       luasec                1.3.2\n'
    '  install_rock lunarmodules  luasocket             3.0rc1\n'
    '  install_rock tieske        penlight              1.14.0\n'
    '  install_rock pintsized     lua-resty-http        0.17.2\n'
    '  install_rock thibaultcha   lua-resty-jit-uuid    0.0.7\n'
    '  install_rock hamish        lua-ffi-zlib          0.6\n'
    '  install_rock kong          multipart             0.5.9\n'
    '  install_rock kong          version               1.0.1\n'
    '  install_rock kong          kong-lapis            1.16.0.1\n'
    '  install_rock kong          kong-pgmoon           1.16.2\n'
    '  install_rock daurnimator   luatz                 0.4\n'
    '  install_rock kong          lua_system_constants  0.1.4\n'
    '  install_rock gvvaughan     lyaml                 6.2.8\n'
    '  install_rock tieske        luasyslog             2.0.1\n'
    '  install_rock kong          lua_pack              2.0.0\n'
    '  install_rock tieske        binaryheap            0.4\n'
    '  install_rock szensk        luaxxhash             1.0.0\n'
    '  install_rock xavier-wang   lua-protobuf          0.5.2\n'
    '  install_rock kong          lua-resty-healthcheck 3.1.0\n'
    '  install_rock fperrad       lua-messagepack       0.5.4\n'
    '  install_rock kong          lua-resty-aws         1.5.4\n'
    '  install_rock fffonion      lua-resty-openssl     1.5.1\n'
    '  install_rock kong          lua-resty-gcp         0.0.13\n'
    '  install_rock kong          lua-resty-counter     0.2.1\n'
    '  install_rock membphis      lua-resty-ipmatcher   0.6.1\n'
    '  install_rock fffonion      lua-resty-acme        0.15.0\n'
    '  install_rock bungle        lua-resty-session     4.0.5\n'
    '  install_rock kong          lua-resty-timer-ng    0.2.7\n'
    '  install_rock gvvaughan     lpeg                  1.1.0\n'
    '  install_rock tieske        lua-resty-ljsonschema 1.2.0\n'
    '  install_rock bungle        lua-resty-snappy      1.0\n'
    '  install_rock bungle        lua-resty-ada         1.1.0\n'
    '\n'
    '  with_backoff /usr/local/bin/luarocks make kong-${ROCKSPEC_VERSION}.rockspec \\\n'
    '    --deps-mode none \\\n'
    '    CRYPTO_DIR=/usr/local/kong \\\n'
    '    OPENSSL_DIR=/usr/local/kong \\\n'
    '    YAML_LIBDIR=/tmp/build/usr/local/kong/lib \\\n'
    '    YAML_INCDIR=/tmp/yaml \\\n'
    '    EXPAT_DIR=/usr/local/kong \\\n'
    '    LIBXML2_DIR=/usr/local/kong \\\n'
    '    CFLAGS="-L/tmp/build/usr/local/kong/lib -Wl,-rpath,/usr/local/kong/lib -O2 -std=gnu99 -fPIC"\n'
)

if OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> per-author dep installs + --deps-mode none added to build-kong.sh")
else:
    sys.exit("  !! expected luarocks make block not found — upstream layout changed")
PYEOF
fi

# ─── Remove stale openresty Docker image ──────────────────────────────────────
OPENRESTY_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${DOCKER_REPOSITORY}:openresty-" | head -1 || true)
if [ -n "${OPENRESTY_TAG}" ]; then
  log "Removing stale openresty Docker image: ${OPENRESTY_TAG}"
  docker rmi -f "${OPENRESTY_TAG}" 2>/dev/null || true
fi

# ─── Build local kong/fpm:0.5.1 image for arm64 ──────────────────────────────
# DOCKER_DEFAULT_PLATFORM=linux/arm64 is active, so this builds arm64
if ! docker image inspect kong/fpm:0.5.1 &>/dev/null || \
   [ "$(docker image inspect kong/fpm:0.5.1 --format '{{.Architecture}}')" != "arm64" ]; then
  log "Building arm64 kong/fpm:0.5.1 image (QEMU emulated) ..."
  docker rmi -f kong/fpm:0.5.1 2>/dev/null || true
  docker build -t kong/fpm:0.5.1 - << 'FPMEOF'
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ruby ruby-dev build-essential libffi-dev rpm squashfs-tools && \
    gem install fpm --no-document && \
    rm -rf /var/lib/apt/lists/*
FPMEOF
  log "  -> arm64 kong/fpm:0.5.1 built"
else
  log "arm64 kong/fpm:0.5.1 already present — skipping build"
fi

# ─── Create dummy GPG key file ────────────────────────────────────────────────
DUMMY_KEY="${BUILD_TOOLS_DIR}/kong.private.gpg-key.asc"
if [ ! -f "${DUMMY_KEY}" ]; then
  log "Creating empty placeholder ${DUMMY_KEY} ..."
  touch "${DUMMY_KEY}"
fi

# ─── Force arm64 base for the package wrapper stage ───────────────────────────
# dockerfiles/Dockerfile.package's final stage is `FROM alpine`. The legacy
# docker builder (DOCKER_BUILDKIT=0, used by this script) ignores
# DOCKER_DEFAULT_PLATFORM for an already-cached base and reuses whatever
# `alpine:latest` is in the local image store. If that cached alpine is amd64,
# the resulting kong-packaged image is amd64 — even though the kong/openresty
# stages are arm64. Then `docker run` (with DOCKER_DEFAULT_PLATFORM=linux/arm64)
# can't find an arm64 variant locally and tries to PULL ${DOCKER_REPOSITORY},
# failing with "pull access denied". Pre-pull arm64 alpine so the wrapper stage
# is built for arm64 and the local tag matches the run platform.
log "Pre-pulling arm64 alpine for the package wrapper stage ..."
docker pull --platform="${TARGET_PLATFORM}" alpine:latest

# Drop any stale packaged image so the run picks up the freshly built arm64 one.
STALE_PKG=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep "^${DOCKER_REPOSITORY}:kong-packaged-" || true)
if [ -n "${STALE_PKG}" ]; then
  log "Removing stale packaged image(s):"
  echo "${STALE_PKG}" | while read -r t; do
    [ -n "${t}" ] && docker rmi -f "${t}" 2>/dev/null || true
  done
fi

# ─── Run make package-kong for arm64 ──────────────────────────────────────────
log "Starting Kong arm64 build ..."
log "  TARGET_PLATFORM     = ${TARGET_PLATFORM}"
log "  KONG_VERSION        = ${KONG_VERSION}"
log "  RESTY_VERSION       = ${RESTY_VERSION}"
log "  LUAROCKS            = ${RESTY_LUAROCKS_VERSION}"
log "  RESTY_OPENSSL_VER   = ${RESTY_OPENSSL_VERSION}"
log "  RESTY_PCRE_VERSION  = ${RESTY_PCRE_VERSION}"
log "  RESTY_IMAGE_BASE    = ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}"
log "  DOCKER_REPOSITORY   = ${DOCKER_REPOSITORY}"
log ""

# Pass TARGETPLATFORM=linux/arm64 so fpm-entrypoint.sh names the .deb correctly.
# DOCKER_DEFAULT_PLATFORM=linux/arm64 ensures all intermediate images are arm64.
LOCAL_DOCKER_CMD="docker build --build-arg TARGETPLATFORM=${TARGET_PLATFORM}"

make -C "${BUILD_TOOLS_DIR}" package-kong \
  KONG_SOURCE_LOCATION="${KONG_SOURCE_DIR}" \
  KONG_VERSION="${KONG_VERSION}" \
  KONG_TAG="${KONG_TAG}" \
  RESTY_VERSION="${RESTY_VERSION}" \
  RESTY_LUAROCKS_VERSION="${RESTY_LUAROCKS_VERSION}" \
  RESTY_OPENSSL_VERSION="${RESTY_OPENSSL_VERSION}" \
  KONG_OPENSSL_VERSION="${KONG_OPENSSL_VERSION}" \
  RESTY_PCRE_VERSION="${RESTY_PCRE_VERSION}" \
  RESTY_IMAGE_BASE="${RESTY_IMAGE_BASE}" \
  RESTY_IMAGE_TAG="${RESTY_IMAGE_TAG}" \
  PACKAGE_TYPE="${PACKAGE_TYPE}" \
  DOCKER_REPOSITORY="${DOCKER_REPOSITORY}" \
  SSL_PROVIDER="${SSL_PROVIDER}" \
  OPENRESTY_PATCHES=1 \
  CACHE=false \
  BUILDX=false \
  "DOCKER_COMMAND=${LOCAL_DOCKER_CMD}"

# ─── Copy output ──────────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
# fpm-entrypoint.sh names the package kong-${KONG_VERSION}.${RESTY_IMAGE_TAG}.${arch}.deb.
# Rename it to embed the OpenResty version so the multi-arch Dockerfile can COPY a
# stable, OpenResty-versioned filename for both arm64 and amd64.
ARCH="${TARGET_PLATFORM##*/}"
DEB_NAME="kong-${KONG_VERSION}-openresty${RESTY_VERSION}.${ARCH}.deb"
SRC_DEB=$(ls -t "${BUILD_TOOLS_DIR}/output/"*.deb 2>/dev/null | head -n1)
if [ -n "${SRC_DEB}" ]; then
  cp -v "${SRC_DEB}" "${OUTPUT_DIR}/${DEB_NAME}"
else
  cp -v "${BUILD_TOOLS_DIR}/output/"* "${OUTPUT_DIR}/" 2>/dev/null || \
    log "(no output files found in ${BUILD_TOOLS_DIR}/output/)"
fi

log "Build complete! Packages:"
ls -lh "${OUTPUT_DIR}/"
