#!/usr/bin/env bash
# =============================================================================
#  build-kong-3.9.2-amd64.sh
#  Build Kong OSS 3.9.2 amd64 .deb using SuriyaRuk/kong-build-tools
#  OpenResty: 1.31.1.1   |   Base OS: Ubuntu 22.04
#
#  Output: output/kong-3.9.1.20.04.amd64.deb
# =============================================================================
set -euo pipefail

# ─── Versions ─────────────────────────────────────────────────────────────────
KONG_VERSION="3.9.2"
KONG_TAG="3.9.2"
RESTY_VERSION="1.31.1.1"
# Kong 3.9.1's .requirements uses `LUAROCKS=` but the Makefile greps for
# `RESTY_LUAROCKS_VERSION=` → resolves empty → build-openresty.sh passes
# `--luarocks` with no value, which eats the next flag and fails the build.
# Must match LUAROCKS= in Kong 3.9.1/.requirements (3.11.1). Earlier versions
# like 3.5.6 do not exist on luarocks.org or github.com/luarocks/luarocks → 404.
RESTY_LUAROCKS_VERSION="3.12.2"

# .requirements has `OPENSSL=3.2.3` but the Makefile greps for
# `RESTY_OPENSSL_VERSION=` → empty → build-openresty.sh treats it as "0" →
# kong-ngx-build fails with: FATAL: OpenSSL version not specified.
# Pin RESTY_OPENSSL_VERSION explicitly to build actual OpenSSL 3.2.3 from source.
RESTY_OPENSSL_VERSION="3.5.6"
# KONG_OPENSSL_VERSION is a DIFFERENT variable: it's the release tag of
# github.com/Kong/kong-openssl (prebuilt library), whose valid tags are 1.0.0-1.5.0.
# It is NOT the OpenSSL version. If set to "3.2.3", kong-ngx-build tries to
# download https://github.com/Kong/kong-openssl/releases/download/3.2.3/<arch>.tar.gz
# which 404s. Set to 0 so the prebuilt path is skipped and OpenSSL is built
# from source using RESTY_OPENSSL_VERSION above.
KONG_OPENSSL_VERSION="0"
RESTY_PCRE_VERSION="10.46"

# ─── Paths ────────────────────────────────────────────────────────────────────
# IMPORTANT: Makefile uses `cp -R $(KONG_SOURCE_LOCATION) kong` without quoting,
# so ANY space in the path breaks the copy with "cp: kong: Not a directory".
# The outputs folder is inside "Application Support" (has spaces) – use /tmp.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TOOLS_DIR="/tmp/kong-build-tools-392-amd64"
KONG_SOURCE_DIR="/tmp/kong-source-392-amd64"
# Final .deb packages will be copied back here after build
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ─── Build settings ───────────────────────────────────────────────────────────
RESTY_IMAGE_BASE="ubuntu"
RESTY_IMAGE_TAG="26.04"
PACKAGE_TYPE="deb"
# Use a plain local name (no registry prefix).
# If DOCKER_REPOSITORY has a hostname (e.g. ghcr.io/...), BuildKit always tries
# to pull the intermediate openresty image from that registry – even if it was
# just built locally – because `docker buildx build` without --load doesn't
# persist images in the local Docker daemon.
DOCKER_REPOSITORY="kong-build-local-amd64"
SSL_PROVIDER="openssl"
TARGET_PLATFORM="linux/amd64"
TARGET_ARCH="amd64"

# ─── Helper ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

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

# ─── 4. Patch known bug: duplicate healthcheck in test compose file ───────────
# Upstream repo has 'healthcheck' key defined twice in the db service, which
# causes docker-compose to fail with "mapping key already defined".
# We keep only the second (better) definition: interval=5s, retries=10.
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

# ─── 6. Patch Dockerfiles ─────────────────────────────────────────────────────
# We use DOCKER_BUILDKIT=0 (legacy builder) so that FROM resolves from the
# local Docker daemon image store without any registry lookup.
#
# Legacy builder does NOT support:
#   (A) `# syntax = docker/dockerfile:1.2`  → remove it
#   (B) `RUN --mount=type=secret,...`        → strip the mount option
#       (For Kong OSS, post-install.sh does not exist, so the secret is a no-op)

python3 - "${BUILD_TOOLS_DIR}/dockerfiles" << 'PYEOF'
import sys, pathlib, re

ddir = pathlib.Path(sys.argv[1])
for name in ("Dockerfile.openresty", "Dockerfile.kong"):
    df = ddir / name
    if not df.exists():
        continue
    text = df.read_text()

    # (A) remove `# syntax = ...` directive
    text = re.sub(r'^# syntax\s*=.*\n', '', text, flags=re.MULTILINE)

    # (B) replace  RUN --mount=type=secret,id=github-token <CMD>
    #         with  RUN <CMD>
    # The replaced command still checks `if [ -f /distribution/post-install.sh ]`
    # which is false for Kong OSS – so it is a safe no-op.
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

# ─── Patch C: remove --secret flag from Makefile ─────────────────────────────
# Legacy builder also doesn't support `--secret` passed via DOCKER_COMMAND in
# the Makefile.  Safe to remove for Kong OSS (no enterprise secrets needed).
MAKEFILE="${BUILD_TOOLS_DIR}/Makefile"
if [ -f "${MAKEFILE}" ]; then
  sed -i.bak '/--secret id=github-token,src=github-token/d' "${MAKEFILE}"
  log "Patched Makefile: removed --secret lines"
fi

# ─── Patch D: strip trailing '# comment' from Kong .requirements ──────────────
# Kong 3.9.1's .requirements has lines like:
#   LUA_KONG_NGINX_MODULE=ddc1f95... # 0.13.2
# The Makefile extracts values via `awk -F"=" '{print $2}'`, which keeps the
# trailing ' # <version>'.  When rendered into
#   --build-arg KONG_NGINX_MODULE=ddc1f95... # 0.13.2 \
# the '#' starts a shell comment, swallows the '\' line continuation, and
# truncates `docker build` before it gets its PATH argument → error:
#   "'docker build' requires 1 argument"
# Strip the comments once, up-front, so every grep-based extraction is clean.
REQ_FILE="${KONG_SOURCE_DIR}/.requirements"
if [ -f "${REQ_FILE}" ] && grep -qE '[[:space:]]+#' "${REQ_FILE}"; then
  log "Stripping inline '# comment' suffixes from ${REQ_FILE}"
  sed -i.bak -E 's/[[:space:]]+#.*$//' "${REQ_FILE}"
fi

# ─── Patch E: teach kong-ngx-build to download PCRE2 ─────────────────────────
# Kong 3.9.1 requires PCRE 10.44 — which is PCRE2, hosted on GitHub.
# kong-ngx-build was written for PCRE1 and hard-codes the old SourceForge URL:
#   https://downloads.sourceforge.net/project/pcre/pcre/10.44/pcre-10.44.tar.gz
# That URL 404s and SourceForge returns an HTML error page. curl saves the
# HTML as pcre-10.44.tar.gz, then `tar -xzf` fails with:
#   gzip: stdin: not in gzip format
#   tar: Child returned status 1
# Rewrite the PCRE block so versions starting with "10." fetch PCRE2 from
# github.com/PCRE2Project/pcre2 and get symlinked into the pcre-$VER path
# the rest of the script expects.  OpenResty 1.29.2.1 (nginx ≥ 1.21.5) accepts
# PCRE2 directly via --with-pcre=<path>.
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
    '          # PCRE2 — lives on GitHub, archive name is pcre2-*.\n'
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
# The upstream script has a copy-paste bug: the OpenResty download block uses
# the lua-resty-websocket URL instead of the correct openresty.org URL, so
# openresty-$OPENRESTY_VER.tar.gz is never created and sha256sum/tar fail.
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: fixing OpenResty download URL"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib, re

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
# RESTY_WEBSOCKET from .requirements is a commit hash, not a tag name.
# The script uses refs/tags/ in the URL which only works for named tags.
# Dropping refs/tags/ makes GitHub's archive endpoint work for both.
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: fixing lua-resty-websocket download URL (commit hash vs tag)"
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
# lua-kong-nginx-module (Kong 3.9.1, commit ddc1f95) calls cctx->disable_http2_alpn
# but OpenResty 1.29.2.5 bundles ngx_lua-0.10.31rc2 whose ngx_http_lua_ssl_ctx_t
# does not have this bit-field.  Result: OpenResty fails to compile, nginx is
# never installed to /tmp/build, and luarocks configure later can't find luajit.
# Fix: write a patch file into the 1.29.2.5 patches directory so kong-ngx-build
# (OPENRESTY_PATCHES=1) applies it before running ./configure.
# NOTE: kong-ngx-build applies the patch with `patch -p1` from the bundle dir, so
# the path inside the patch header MUST match the bundled ngx_lua directory name
# (ngx_lua-0.10.31rc2 in OpenResty 1.29.2.5 — not 0.10.30rc2 as in 1.29.2.3).
PATCHES_DIR="${BUILD_TOOLS_DIR}/openresty-patches/patches/1.29.2.5"
mkdir -p "${PATCHES_DIR}"
# Remove any stale patch targeting the old ngx_lua-0.10.30rc2 dir; otherwise the
# kong-ngx-build glob still picks it up and fails with "can't find file to patch".
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
# After trying the primary LuaRocks download URL, the script does `set +e` and
# then is supposed to restore errexit with `set -e`.  A typo writes `set -e/`
# instead.  In bash, `-e/` is not a valid option, so errexit is NEVER restored.
# From that point on, ALL subsequent errors (configure, make) are silently
# swallowed — including the OpenResty compile failure above — causing the
# script to print "SUCCESS" even though nothing was actually installed.
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

# ─── Patch I: clear stale LuaRocks manifest cache in build-kong.sh ───────────
# The base image (kong/kong-build-tools:deb-1.8.3) was built when luarocks.org
# served a single monolithic manifest-5.1 file.  That file has since grown to
# 235,559+ constants — beyond Lua 5.1/LuaJIT's 65,536-per-function limit —
# causing every `luarocks make` invocation to fail with:
#   "main function has more than 65536 constants"
# LuaRocks 3.9.0+ downloads the manifest in smaller numbered chunks
# (manifest-5.1.1, manifest-5.1.2, …) that each stay within the limit, BUT
# only if /var/cache/luarocks/ is empty so it fetches the current format.
# Clearing the cache here forces LuaRocks to re-download the chunked manifests
# instead of reusing the stale monolithic one baked into the base image.
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
BUILD_KONG_SH="${BUILD_TOOLS_DIR}/build-kong.sh"
if [ -f "${BUILD_KONG_SH}" ]; then
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

# ─── Patch K: force OpenSSL to install libs into 'lib' not 'lib64' ───────────
# On x86_64, OpenSSL 3.x defaults to LIBDIR=lib64.  kong-ngx-build passes
# --with-ld-opt='-L$OPENSSL_INSTALL/lib ...' to OpenResty's configure, so the
# linker searches 'lib' and falls back to system OpenSSL 1.1.1 (Ubuntu 20/22),
# which lacks the OpenSSL 3.x APIs (SSL_get1_peer_certificate, etc.) → link error.
# Adding --libdir=lib to ./config forces OpenSSL to install to 'lib', matching
# the path the linker actually searches.
NGX_BUILD_FILE="${BUILD_TOOLS_DIR}/openresty-build-tools/kong-ngx-build"
if [ -f "${NGX_BUILD_FILE}" ]; then
  log "Patching ${NGX_BUILD_FILE}: add --libdir=lib to OpenSSL configure opts"
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

MARKER = '"--libdir=lib"'
OLD = (
    '            OPENSSL_OPTS=(\n'
    '              "-g"\n'
    '              "shared"\n'
    '              "-DPURIFY"\n'
    '              "no-threads"\n'
    '              "--prefix=$OPENSSL_PREFIX"\n'
    '              "--openssldir=$OPENSSL_PREFIX"\n'
    '            )\n'
)
NEW = (
    '            OPENSSL_OPTS=(\n'
    '              "-g"\n'
    '              "shared"\n'
    '              "-DPURIFY"\n'
    '              "no-threads"\n'
    '              "--prefix=$OPENSSL_PREFIX"\n'
    '              "--openssldir=$OPENSSL_PREFIX"\n'
    '              "--libdir=lib"\n'
    '            )\n'
)

if MARKER in text:
    print("  -> already patched, skipping")
elif OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> --libdir=lib added to OpenSSL configure opts")
else:
    sys.exit("  !! expected OPENSSL_OPTS block not found — upstream layout changed")
PYEOF
fi

# ─── Patch L: fix Makefile cascade — Dockerfile.kong runs even when build-openresty fails ──
# In actual-build-kong target, semicolons (;) after `$(MAKE) build-openresty && ...`
# cause `echo ... > github-token` and `$(DOCKER_COMMAND) -f Dockerfile.kong` to run
# regardless of whether build-openresty succeeded. This means a failed openresty build
# produces a confusing secondary error about the base image not found. Fix: replace ; with &&
MAKEFILE_PATH="${BUILD_TOOLS_DIR}/Makefile"
if [ -f "${MAKEFILE_PATH}" ]; then
  log "Patching Makefile: fix cascade semicolons in actual-build-kong target"
  python3 - "${MAKEFILE_PATH}" << 'PYEOF'
import sys, pathlib

f = pathlib.Path(sys.argv[1])
text = f.read_text()

OLD = (
    "\t( $(MAKE) build-openresty && \\\n"
    "\t-rm github-token; \\\n"
    "\techo $$GITHUB_TOKEN > github-token; \\\n"
    "\t$(DOCKER_COMMAND) -f dockerfiles/Dockerfile.kong \\\n"
)
NEW = (
    "\t( $(MAKE) build-openresty && \\\n"
    "\t-rm github-token; \\\n"
    "\techo $$GITHUB_TOKEN > github-token && \\\n"
    "\t$(DOCKER_COMMAND) -f dockerfiles/Dockerfile.kong \\\n"
)

if NEW.split('\n')[2] in text:
    print("  -> already patched, skipping")
elif OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
    print("  -> semicolons fixed to && in actual-build-kong")
else:
    print("  -> pattern not found, skipping (may have changed upstream)")
PYEOF
fi

# ─── Pin BUILD_TOOLS_SHA so all Docker image tags are deterministic ───────────
# The Makefile derives every image suffix (DOCKER_KONG_SUFFIX, DOCKER_OPENRESTY_SUFFIX,
# etc.) from `BUILD_TOOLS_SHA=$(git rev-parse --short HEAD)`, declared with `=`
# (recursively expanded). That command is therefore re-run on *every* reference to
# the suffix. If HEAD moves between the `docker build -t ...` step and the later
# `docker run ...` step — e.g. a commit/amend/rebase lands, or git resolves a
# different repo depending on the recipe's CWD — the run step looks for an image
# tag that was never created and fails with "pull access denied / Error 125".
# Compute the SHA once here and pass it as a make command-line override (constant,
# never re-evaluated) so the build-tag and docker-run steps always agree and the
# already-built ${BUILD_TOOLS_SHA} images are reused from cache.
BUILD_TOOLS_SHA="$(git -C "${BUILD_TOOLS_DIR}" rev-parse --short HEAD)"
log "Pinned BUILD_TOOLS_SHA=${BUILD_TOOLS_SHA} for deterministic image tags"

# ─── Remove stale openresty Docker image so it rebuilds with the new patch ────
# The openresty image was cached from a previous run in which the OpenResty build
# silently failed (due to the set -e/ typo).  That cached image has no nginx or
# luarocks binaries.  Remove it so Docker rebuilds from scratch with Patch H.
OPENRESTY_SUFFIX_CMD="make -C ${BUILD_TOOLS_DIR} --no-print-directory print-openresty-docker-suffix \
  BUILD_TOOLS_SHA=${BUILD_TOOLS_SHA} \
  KONG_SOURCE_LOCATION=${KONG_SOURCE_DIR} \
  RESTY_VERSION=${RESTY_VERSION} \
  RESTY_LUAROCKS_VERSION=${RESTY_LUAROCKS_VERSION} \
  RESTY_OPENSSL_VERSION=${RESTY_OPENSSL_VERSION} \
  KONG_OPENSSL_VERSION=${KONG_OPENSSL_VERSION} \
  RESTY_PCRE_VERSION=${RESTY_PCRE_VERSION} \
  RESTY_IMAGE_BASE=${RESTY_IMAGE_BASE} \
  RESTY_IMAGE_TAG=${RESTY_IMAGE_TAG} \
  PACKAGE_TYPE=${PACKAGE_TYPE} \
  DOCKER_REPOSITORY=${DOCKER_REPOSITORY} \
  SSL_PROVIDER=${SSL_PROVIDER} 2>/dev/null"
OPENRESTY_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${DOCKER_REPOSITORY}:openresty-" | head -1 || true)
if [ -n "${OPENRESTY_TAG}" ]; then
  log "Removing stale openresty Docker image: ${OPENRESTY_TAG}"
  docker rmi -f "${OPENRESTY_TAG}" 2>/dev/null || true
fi

# ─── 7. Pre-build disk space check and Docker cleanup ────────────────────────
# Building OpenResty + Kong requires ~8-10 GB of Docker layer space.
# Prune dangling images and stopped containers to reclaim space before build.
log "Pruning dangling Docker images and stopped containers to free disk space ..."
docker image prune -f 2>/dev/null || true
docker container prune -f 2>/dev/null || true
AVAIL_KB=$(df --output=avail / 2>/dev/null | tail -1 || echo 0)
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if [ "${AVAIL_GB}" -lt 8 ]; then
  log "WARNING: Only ${AVAIL_GB}GB free on /. Build may fail with 'no space left on device'."
  log "         Run: docker system prune -af   to free more space before retrying."
fi

# ─── 7b_env. Use the legacy builder so intermediate images land in local daemon ──
# DOCKER_BUILDKIT=0 forces the classic (non-buildx) builder. The classic builder
# always stores built images directly in the local daemon, so the
# `FROM kong-build-local-amd64:openresty-...` reference in Dockerfile.kong resolves
# locally. This mirrors the proven arm64 build path exactly (only the platform
# differs). DOCKER_DEFAULT_PLATFORM=linux/amd64 makes every intermediate image
# build for amd64 via QEMU emulation on this arm64 host.
#
# NOTE: We deliberately do NOT use `docker buildx build --load` here. buildx runs
# on BuildKit, whose FROM resolution does not reliably see classic-daemon images;
# when the openresty image isn't found it falls back to pulling
# docker.io/library/kong-build-local-amd64:openresty-... which fails with
# "pull access denied, repository does not exist". The upstream Makefile recipe
# (actual-build-kong) also chains the kong build after build-openresty with `;`
# instead of `&&`, so a failed/unloaded openresty image still triggers the kong
# build and surfaces as that confusing pull error.
export DOCKER_DEFAULT_PLATFORM=linux/amd64
export DOCKER_BUILDKIT=0

# ─── 7b. Build local kong/fpm:0.5.1 image if not available ───────────────────
# Dockerfile.package uses `FROM kong/fpm:0.5.1` which is a private Kong Docker
# Hub image (requires login). Build an equivalent image locally using the public
# ubuntu:22.04 base + fpm gem so no Docker Hub auth is needed.
if ! docker image inspect kong/fpm:0.5.1 &>/dev/null || \
   [ "$(docker image inspect kong/fpm:0.5.1 --format '{{.Architecture}}')" != "amd64" ]; then
  log "Building amd64 kong/fpm:0.5.1 image ..."
  docker rmi -f kong/fpm:0.5.1 2>/dev/null || true
  docker build -t kong/fpm:0.5.1 - << 'FPMEOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ruby ruby-dev build-essential libffi-dev rpm squashfs-tools && \
    gem install fpm --no-document && \
    rm -rf /var/lib/apt/lists/*
FPMEOF
  log "  -> amd64 kong/fpm:0.5.1 built successfully"
else
  log "amd64 kong/fpm:0.5.1 already present locally — skipping build"
fi

# ─── 7c. Create dummy GPG key file for Dockerfile.package COPY ───────────────
# Dockerfile.package does `COPY ${PRIVATE_KEY_FILE} /kong.private.asc` where
# PRIVATE_KEY_FILE=kong.private.gpg-key.asc (hardcoded in Makefile).  The key
# is only used for RPM signing (PRIVATE_KEY_PASSPHRASE set), which we never do.
# The file must exist in the build context or `docker build` fails.  Create an
# empty placeholder if it isn't already there.
DUMMY_KEY="${BUILD_TOOLS_DIR}/kong.private.gpg-key.asc"
if [ ! -f "${DUMMY_KEY}" ]; then
  log "Creating empty placeholder ${DUMMY_KEY} (not used for deb builds) ..."
  touch "${DUMMY_KEY}"
fi

# ─── 7d. Ensure amd64 alpine base for the package wrapper image ──────────────
# Dockerfile.package's final stage is `FROM alpine` (a throwaway wrapper whose
# only job is to hold /output so the Makefile can `docker run ... tail -f
# /dev/null` + `docker cp` the built .deb out). The classic builder
# (DOCKER_BUILDKIT=0) reuses whatever `alpine:latest` is already cached locally
# REGARDLESS of DOCKER_DEFAULT_PLATFORM — it only resolves platform on a pull,
# not for a tag that already exists. On this arm64 host the cached alpine:latest
# is arm64, so the wrapper image is built arm64 while the rest of the pipeline
# (openresty, kong-deb, the .deb itself) is correctly amd64.
#
# The Makefile then runs `docker run ... kong-packaged-...` under the exported
# DOCKER_DEFAULT_PLATFORM=linux/amd64, which demands an amd64 wrapper, fails to
# find one locally, falls back to pulling kong-build-local-amd64 from Docker Hub,
# and dies with "pull access denied ... Error 125".
#
# Pull the amd64 alpine manifest so `alpine:latest` points at the amd64 image;
# the `FROM alpine` cache key then changes, the wrapper rebuilds as amd64, and
# the extraction `docker run` finds it. (Mirrors the amd64 kong/fpm:0.5.1 fix.)
log "Ensuring amd64 alpine base image for the package wrapper ..."
docker pull --platform=linux/amd64 alpine:latest >/dev/null
# Drop the stale arm64 wrapper tag so nothing can reuse it as an amd64 image.
STALE_WRAPPER=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep "^${DOCKER_REPOSITORY}:kong-packaged-" || true)
if [ -n "${STALE_WRAPPER}" ]; then
  STALE_ARCH=$(docker image inspect "${STALE_WRAPPER}" --format '{{.Architecture}}' 2>/dev/null || echo "")
  if [ "${STALE_ARCH}" != "amd64" ]; then
    log "Removing stale ${STALE_ARCH:-unknown}-arch wrapper image: ${STALE_WRAPPER}"
    docker rmi -f "${STALE_WRAPPER}" 2>/dev/null || true
  fi
fi

# ─── 8. Run make package-kong ─────────────────────────────────────────────────
log "Starting Kong amd64 build ..."
log "  TARGET_PLATFORM     = ${TARGET_PLATFORM}"
log "  KONG_VERSION        = ${KONG_VERSION}"
log "  KONG_TAG            = ${KONG_TAG}"
log "  RESTY_VERSION       = ${RESTY_VERSION}"
log "  LUAROCKS            = ${RESTY_LUAROCKS_VERSION}"
log "  RESTY_OPENSSL_VER   = ${RESTY_OPENSSL_VERSION}"
log "  KONG_OPENSSL_VER    = ${KONG_OPENSSL_VERSION}"
log "  RESTY_PCRE_VERSION  = ${RESTY_PCRE_VERSION}"
log "  RESTY_IMAGE_BASE    = ${RESTY_IMAGE_BASE}:${RESTY_IMAGE_TAG}"
log "  PACKAGE_TYPE        = ${PACKAGE_TYPE}"
log "  DOCKER_REPOSITORY   = ${DOCKER_REPOSITORY}"
log ""

# Pass TARGETPLATFORM=linux/amd64 so fpm-entrypoint.sh names the .deb correctly.
# Use the classic builder (DOCKER_BUILDKIT=0 set above): every intermediate image
# lands in the local daemon, so the openresty image built by `make build-openresty`
# is found when Dockerfile.kong does `FROM kong-build-local-amd64:openresty-...`.
# This is identical to the working arm64 path, just targeting linux/amd64.
LOCAL_DOCKER_CMD="docker build --build-arg TARGETPLATFORM=${TARGET_PLATFORM}"

make -C "${BUILD_TOOLS_DIR}" package-kong \
  BUILD_TOOLS_SHA="${BUILD_TOOLS_SHA}" \
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

# ─── 8. Copy output back to script directory ──────────────────────────────────
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
