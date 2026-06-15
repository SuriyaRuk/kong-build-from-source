#!/usr/bin/env bash
# =============================================================================
#  build-kong-3.9.2-1.31.1-rpm-amd64.sh
#  Build Kong OSS 3.9.2 amd64 .rpm using SuriyaRuk/kong-build-tools
#  OpenResty: 1.31.1.1   |   Base OS: Amazon Linux 2023
#
#  Output: output/kong-3.9.2-openresty1.31.1.1.amd64.rpm
# =============================================================================
set -euo pipefail

# ─── Versions ─────────────────────────────────────────────────────────────────
KONG_VERSION="3.9.2"
KONG_TAG="3.9.2"
RESTY_VERSION="1.31.1.1"
RESTY_LUAROCKS_VERSION="3.12.2"
RESTY_OPENSSL_VERSION="3.5.7"
KONG_OPENSSL_VERSION="0"
RESTY_PCRE_VERSION="10.46"

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TOOLS_DIR="/tmp/kong-build-tools-392-rpm-amd64"
KONG_SOURCE_DIR="/tmp/kong-source-392-rpm-amd64"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# ─── Build settings ───────────────────────────────────────────────────────────
RESTY_IMAGE_BASE="amazonlinux"
RESTY_IMAGE_TAG="2023"
PACKAGE_TYPE="rpm"
DOCKER_REPOSITORY="kong-build-local-rpm-amd64"
SSL_PROVIDER="openssl"
TARGET_PLATFORM="linux/amd64"
TARGET_ARCH="amd64"

# ─── Helper ───────────────────────────────────────────────────────────────────
log()  { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# ─── 0. Set up QEMU for amd64 emulation (if needed) ───────────────────────────
HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64|amd64)
    log "Host is ${HOST_ARCH}; amd64 build is native — skipping QEMU registration." ;;
  *)
    log "Host is ${HOST_ARCH}; registering QEMU for amd64 emulation ..."
    docker run --rm --privileged tonistiigi/binfmt --install amd64
    log "  -> QEMU amd64 registered" ;;
esac

# ─── 1. Clone / update kong-build-tools ───────────────────────────────────────
if [ ! -d "${BUILD_TOOLS_DIR}" ]; then
  log "Cloning SuriyaRuk/kong-build-tools ..."
  git clone https://github.com/SuriyaRuk/kong-build-tools.git "${BUILD_TOOLS_DIR}"
else
  log "kong-build-tools already present – pulling latest master ..."
  git -C "${BUILD_TOOLS_DIR}" checkout master
  git -C "${BUILD_TOOLS_DIR}" pull
fi

# ─── 2. Clone Kong source at tag 3.9.2 ────────────────────────────────────────
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

# ─── 4. Patch known bug: duplicate healthcheck in test compose file ───────────
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
PYEOF
fi

# ─── 5. Init submodules ────────────────────────────────────────────────────────
log "Initialising submodules in kong-build-tools ..."
git -C "${BUILD_TOOLS_DIR}" submodule update --init --recursive

# ─── 6. Patch Dockerfiles ─────────────────────────────────────────────────────
python3 - "${BUILD_TOOLS_DIR}/dockerfiles" << 'PYEOF'
import sys, pathlib, re
ddir = pathlib.Path(sys.argv[1])
for name in ("Dockerfile.openresty", "Dockerfile.kong"):
    df = ddir / name
    if not df.exists(): continue
    text = df.read_text()
    text = re.sub(r'^# syntax\s*=.*\n', '', text, flags=re.MULTILINE)
    text = re.sub(r'^(RUN) --mount=type=secret,id=github-token\s+', r'\1 ', text, flags=re.MULTILINE)
    
    # Switch to AlmaLinux 9 as base for RPM builds to avoid CentOS 7 EOL mirrors
    if name == "Dockerfile.openresty":
        text = text.replace('FROM kong/kong-build-tools:rpm-1.8.3 as RPM',
                            'FROM almalinux:9 as RPM\nRUN yum install -y --allowerasing gcc make perl-devel openssl-devel pcre-devel zlib-devel wget curl tar git patch perl-IPC-Cmd perl-FindBin perl-Data-Dumper perl-File-Compare perl-File-Copy perl-Pod-Html perl-Time-Piece')
        text = text.replace('FROM $PACKAGE_TYPE', 'FROM $PACKAGE_TYPE\nRUN yum install -y --allowerasing perl-IPC-Cmd perl-FindBin perl-Data-Dumper perl-File-Compare perl-File-Copy perl-Pod-Html perl-Time-Piece || dnf install -y --allowerasing perl-IPC-Cmd perl-FindBin perl-Data-Dumper perl-File-Compare perl-File-Copy perl-Pod-Html perl-Time-Piece || true')
        # Idempotent safety net: AlmaLinux 9 ships curl-minimal, which conflicts
        # with the full `curl` package. Force --allowerasing on every yum install
        # so the conflict is auto-resolved. This also fixes the case where the
        # base image was already rewritten to almalinux:9 by a prior run / upstream
        # commit (then the FROM .replace above no-ops and the RUN line would
        # otherwise keep running without --allowerasing).
        text = re.sub(r'RUN yum install -y (?!--allowerasing)', 'RUN yum install -y --allowerasing ', text)

        # The stock kong/kong-build-tools:rpm-1.8.3 base shipped libyaml prebuilt
        # in /tmp/build/usr/local/kong/lib (plus yaml.h in /tmp/yaml). Bare
        # almalinux:9 does not, so lyaml's luarocks install later fails with
        # "Could not find library file for YAML" (luarocks honors the explicit
        # YAML_LIBDIR=/tmp/build/usr/local/kong/lib hint and searches ONLY there).
        # Build libyaml 0.2.5 from source — the same version Kong's own Bazel
        # build uses — into /tmp/build/usr/local/kong so it persists into the
        # Dockerfile.kong stage and ends up in the final .rpm. --libdir is pinned
        # to 'lib' (not lib64) to match the YAML_LIBDIR hint, mirroring Patch K.
        libyaml_run = (
            'RUN set -eux; \\\n'
            '    cd /tmp; \\\n'
            '    curl -fSL https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz -o yaml-0.2.5.tar.gz; \\\n'
            '    tar -xzf yaml-0.2.5.tar.gz; \\\n'
            '    cd yaml-0.2.5; \\\n'
            '    ./configure --prefix=/tmp/build/usr/local/kong --libdir=/tmp/build/usr/local/kong/lib; \\\n'
            '    make -j"$(nproc)"; \\\n'
            '    make install; \\\n'
            '    mkdir -p /tmp/yaml; \\\n'
            '    cp -f /tmp/build/usr/local/kong/include/yaml.h /tmp/yaml/\n'
        )
        if 'yaml-0.2.5.tar.gz' not in text:
            text = text.replace('RUN /tmp/build-openresty.sh\n',
                                'RUN /tmp/build-openresty.sh\n' + libyaml_run, 1)

    df.write_text(text)
PYEOF

# ─── Patch C: remove --secret flag from Makefile ─────────────────────────────
MAKEFILE="${BUILD_TOOLS_DIR}/Makefile"
if [ -f "${MAKEFILE}" ]; then
  sed -i.bak '/--secret id=github-token,src=github-token/d' "${MAKEFILE}"
fi

# ─── Patch D: strip trailing '# comment' from Kong .requirements ──────────────
REQ_FILE="${KONG_SOURCE_DIR}/.requirements"
if [ -f "${REQ_FILE}" ]; then
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
if OLD in text: f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── Patch F: fix OpenResty download URL in kong-ngx-build ───────────────────
if [ -f "${NGX_BUILD_FILE}" ]; then
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text()
OLD = "with_backoff curl -fL --retry 3 --retry-delay 2 -sSLO https://github.com/Kong/lua-resty-websocket/archive/${RESTY_WEBSOCKET}.tar.gz"
NEW = "with_backoff curl --fail -sSLO https://openresty.org/download/openresty-$OPENRESTY_VER.tar.gz"
if OLD in text: f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── Patch G: fix lua-resty-websocket download URL ───────────────────────────
if [ -f "${NGX_BUILD_FILE}" ]; then
  sed -i.bak 's/refs\/tags\/${RESTY_WEBSOCKET}/${RESTY_WEBSOCKET}/g' "${NGX_BUILD_FILE}"
fi

# ─── Patch H: add disable_http2_alpn to ngx_http_lua_ssl_ctx_t ───────────────
PATCHES_DIR="${BUILD_TOOLS_DIR}/openresty-patches/patches/1.31.1.1"
mkdir -p "${PATCHES_DIR}"
rm -f "${PATCHES_DIR}"/ngx_lua-0.10.30rc2_*.patch "${PATCHES_DIR}"/ngx_lua-0.10.31rc2_*.patch
PATCH_FILE="${PATCHES_DIR}/ngx_lua-0.10.31rc5_01-add-disable-http2-alpn.patch"
cat > "${PATCH_FILE}" << 'PATCHEOF'
--- a/ngx_lua-0.10.31rc5/src/ngx_http_lua_ssl.h
+++ b/ngx_lua-0.10.31rc5/src/ngx_http_lua_ssl.h
@@ -48,6 +48,7 @@
     unsigned                 entered_client_hello_handler:1;
     unsigned                 entered_cert_handler:1;
     unsigned                 entered_sess_fetch_handler:1;
+    unsigned                 disable_http2_alpn:1;
 #if HAVE_LUA_PROXY_SSL
     unsigned                 entered_proxy_ssl_cert_handler:1;
     unsigned                 entered_proxy_ssl_verify_handler:1;
PATCHEOF

# ─── Patch I: fix 'set -e/' typo in kong-ngx-build ───────────────────────────
if [ -f "${NGX_BUILD_FILE}" ]; then
  sed -i.bak 's/set -e\//set -e/g' "${NGX_BUILD_FILE}"
fi

# ─── Patch I2: clear stale LuaRocks manifest cache in build-kong.sh ──────────
BUILD_KONG_SH="${BUILD_TOOLS_DIR}/build-kong.sh"
if [ -f "${BUILD_KONG_SH}" ]; then
  python3 - "${BUILD_KONG_SH}" << 'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text()
OLD = 'export LUAROCKS_CONFIG=$ROCKS_CONFIG\n'
NEW = 'export LUAROCKS_CONFIG=$ROCKS_CONFIG\nrm -rf /var/cache/luarocks/\n'
if 'rm -rf /var/cache/luarocks/' not in text: f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── Patch J: pre-install Kong deps via per-author luarocks.org manifests ─────
if [ -f "${BUILD_KONG_SH}" ]; then
  python3 - "${BUILD_KONG_SH}" << 'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text()
if 'install_rock ' in text: sys.exit(0)
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
    '  install_rock() {\n'
    '    local author="$1" name="$2" ver="$3"\n'
    '    with_backoff /usr/local/bin/luarocks install "$name" "$ver" --server="https://luarocks.org/manifests/$author" --deps-mode none \\\n'
    '      CRYPTO_DIR=/usr/local/kong OPENSSL_DIR=/usr/local/kong YAML_LIBDIR=/tmp/build/usr/local/kong/lib YAML_INCDIR=/tmp/yaml EXPAT_DIR=/usr/local/kong LIBXML2_DIR=/usr/local/kong CFLAGS="-L/tmp/build/usr/local/kong/lib -Wl,-rpath,/usr/local/kong/lib -O2 -std=gnu99 -fPIC"\n'
    '  }\n'
    '  install_rock kikito inspect 3.1.3\n'
    '  install_rock brunoos luasec 1.3.2\n'
    '  install_rock lunarmodules luasocket 3.0rc1\n'
    '  install_rock tieske penlight 1.14.0\n'
    '  install_rock pintsized lua-resty-http 0.17.2\n'
    '  install_rock thibaultcha lua-resty-jit-uuid 0.0.7\n'
    '  install_rock hamish lua-ffi-zlib 0.6\n'
    '  install_rock kong multipart 0.5.9\n'
    '  install_rock kong version 1.0.1\n'
    '  install_rock kong kong-lapis 1.16.0.1\n'
    '  install_rock kong kong-pgmoon 1.16.2\n'
    '  install_rock daurnimator luatz 0.4\n'
    '  install_rock kong lua_system_constants 0.1.4\n'
    '  install_rock gvvaughan lyaml 6.2.8\n'
    '  install_rock tieske luasyslog 2.0.1\n'
    '  install_rock kong lua_pack 2.0.0\n'
    '  install_rock tieske binaryheap 0.4\n'
    '  install_rock szensk luaxxhash 1.0.0\n'
    '  install_rock xavier-wang lua-protobuf 0.5.2\n'
    '  install_rock kong lua-resty-healthcheck 3.1.0\n'
    '  install_rock fperrad lua-messagepack 0.5.4\n'
    '  install_rock kong lua-resty-aws 1.5.4\n'
    '  install_rock fffonion lua-resty-openssl 1.5.1\n'
    '  install_rock kong lua-resty-gcp 0.0.13\n'
    '  install_rock kong lua-resty-counter 0.2.1\n'
    '  install_rock membphis lua-resty-ipmatcher 0.6.1\n'
    '  install_rock fffonion lua-resty-acme 0.15.0\n'
    '  install_rock bungle lua-resty-session 4.0.5\n'
    '  install_rock kong lua-resty-timer-ng 0.2.7\n'
    '  install_rock gvvaughan lpeg 1.1.0\n'
    '  install_rock tieske lua-resty-ljsonschema 1.2.0\n'
    '  install_rock bungle lua-resty-snappy 1.0\n'
    '  install_rock bungle lua-resty-ada 1.1.0\n'
    '  with_backoff /usr/local/bin/luarocks make kong-${ROCKSPEC_VERSION}.rockspec --deps-mode none \\\n'
    '    CRYPTO_DIR=/usr/local/kong OPENSSL_DIR=/usr/local/kong YAML_LIBDIR=/tmp/build/usr/local/kong/lib YAML_INCDIR=/tmp/yaml EXPAT_DIR=/usr/local/kong LIBXML2_DIR=/usr/local/kong CFLAGS="-L/tmp/build/usr/local/kong/lib -Wl,-rpath,/usr/local/kong/lib -O2 -std=gnu99 -fPIC"\n'
)
if OLD in text: f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── Patch K: force OpenSSL to install libs into 'lib' not 'lib64' ───────────
if [ -f "${NGX_BUILD_FILE}" ]; then
  python3 - "${NGX_BUILD_FILE}" << 'PYEOF'
import sys, pathlib
f = pathlib.Path(sys.argv[1])
text = f.read_text()
OLD = '"--openssldir=$OPENSSL_PREFIX"\n            )\n'
NEW = '"--openssldir=$OPENSSL_PREFIX"\n              "--libdir=lib"\n            )\n'
if '"--libdir=lib"' not in text: f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── Patch L: fix Makefile cascade ────────────────────────────────────────────
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
    "\trm -f github-token; \\\n"
    "\techo $$GITHUB_TOKEN > github-token && \\\n"
    "\t$(DOCKER_COMMAND) -f dockerfiles/Dockerfile.kong \\\n"
)
if NEW.split('\n')[2] in text:
    pass
elif OLD in text:
    f.write_text(text.replace(OLD, NEW, 1))
PYEOF
fi

# ─── 7. Docker and Environment ───────────────────────────────────────────────
# Use the daemon's built-in BuildKit (NOT the legacy builder). The legacy builder
# (DOCKER_BUILDKIT=0) resolves multi-stage `FROM` bases against whatever image is
# already tagged locally, regardless of platform — so on an arm64 host it reuses a
# cached arm64 `almalinux:9`/`amazonlinux:2023` and the amd64 build dies at
# `FROM $PACKAGE_TYPE` with "platform (linux/arm64/v8) does not match linux/amd64".
# BuildKit re-resolves every stage's base by the requested --platform (pulling the
# correct arch via QEMU) while still writing tagged images to the local docker
# image store, which the chained build-openresty -> build-kong step relies on.
export DOCKER_DEFAULT_PLATFORM=linux/amd64
export DOCKER_BUILDKIT=1
BUILD_TOOLS_SHA="$(git -C "${BUILD_TOOLS_DIR}" rev-parse --short HEAD)"

# ─── 7b. Build local kong/fpm:0.5.1 image for amd64 ──────────────────────────
if ! docker image inspect kong/fpm:0.5.1 &>/dev/null || \
   [ "$(docker image inspect kong/fpm:0.5.1 --format '{{.Architecture}}')" != "amd64" ]; then
  log "Building amd64 kong/fpm:0.5.1 image ..."
  docker rmi -f kong/fpm:0.5.1 2>/dev/null || true
  docker build --platform=linux/amd64 -t kong/fpm:0.5.1 - << 'FPMEOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ruby ruby-dev build-essential libffi-dev rpm squashfs-tools && gem install fpm --no-document && rm -rf /var/lib/apt/lists/*
FPMEOF
fi

# ─── 7c. Dummy GPG key ────────────────────────────────────────────────────────
touch "${BUILD_TOOLS_DIR}/kong.private.gpg-key.asc"

# ─── 7d. Ensure amd64 alpine base ────────────────────────────────────────────
log "Ensuring amd64 alpine base image ..."
docker pull --platform=linux/amd64 alpine:latest >/dev/null

# ─── 8. Run make package-kong ─────────────────────────────────────────────────
log "Starting Kong amd64 RPM build ..."
LOCAL_DOCKER_CMD="docker build --platform=${TARGET_PLATFORM} --build-arg TARGETPLATFORM=${TARGET_PLATFORM}"

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

# ─── 9. Copy output ──────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
ARCH="${TARGET_PLATFORM##*/}"
RPM_NAME="kong-${KONG_VERSION}-openresty${RESTY_VERSION}.${ARCH}.rpm"
# fpm-entrypoint.sh names it kong-${KONG_VERSION}.aws.${arch}.rpm for amazonlinux
SRC_RPM=$(ls -t "${BUILD_TOOLS_DIR}/output/"*.rpm 2>/dev/null | head -n1)
if [ -n "${SRC_RPM}" ]; then
  cp -v "${SRC_RPM}" "${OUTPUT_DIR}/${RPM_NAME}"
else
  log "Warning: No RPM found in ${BUILD_TOOLS_DIR}/output/"
fi

log "Build complete! Package: ${OUTPUT_DIR}/${RPM_NAME}"
