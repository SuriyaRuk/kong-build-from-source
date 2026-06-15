# Kong 3.9.1 - CVE Patched Image
# Built from local .deb package with security updates
#
# Build instructions:
#   docker build -t kong-patched:3.9.1-secure .
#
# Security scan:
#   trivy image --severity HIGH,CRITICAL kong-patched:3.9.1-secure

# Stage 1: Base with security updates
FROM ubuntu:26.04 AS secure-base

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get upgrade -y && \
  apt-get dist-upgrade -y && \
  apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  gnupg2 \
  wget \
  apt-transport-https && \
  apt-get autoremove -y && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Stage 2: Kong installation from local .deb
FROM secure-base AS kong-install

# TARGETARCH is automatically set by BuildKit to amd64 or arm64 based on --platform.
# Both output/kong-3.9.1-openresty1.29.2.5.amd64.deb and
# output/kong-3.9.1-openresty1.29.2.5.arm64.deb must exist before running
# docker buildx build --platform linux/amd64,linux/arm64.
ARG TARGETARCH

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  unzip \
  git \
  perl \
  lua5.1 \
  lua-sec \
  lua-socket \
  zlib1g \
  zlib1g-dev \
  libyaml-0-2 \
  libpcre2-8-0 \
  libpcre2-dev && \
  rm -rf /var/lib/apt/lists/*

# Create kong user before installing .deb (in case package postinst fails)
# Ubuntu 24.04 ships with uid 1000 (ubuntu user) — reclaim it for kong
RUN userdel -r ubuntu 2>/dev/null || true && \
  useradd --uid 1000 --user-group --no-create-home kong

# Copy and install local .deb — filename embeds the OpenResty version and matches
# TARGETARCH (amd64 or arm64): kong-3.9.1-openresty1.29.2.5.<arch>.deb
COPY output/kong-3.9.2-openresty1.31.1.1.${TARGETARCH}.deb /tmp/kong.deb
# The .deb declares a stale `libpcre3` dependency (from kong-build-tools'
# fpm-entrypoint.sh). OpenResty 1.31.1.1 here statically links PCRE2 10.46
# (--with-pcre=/work/pcre-10.46), so no dynamic libpcre is needed, and
# libpcre3 (legacy PCRE1) no longer exists on Ubuntu 26.04. Strip the bogus
# dependency from the control file before installing. Idempotent: a no-op
# once the package metadata is fixed upstream.
RUN dpkg-deb -R /tmp/kong.deb /tmp/kong-deb && \
  sed -i -E 's/(^Depends:.*)libpcre3, ?/\1/' /tmp/kong-deb/DEBIAN/control && \
  dpkg-deb --build /tmp/kong-deb /tmp/kong-fixed.deb && \
  dpkg -i /tmp/kong-fixed.deb && \
  rm -rf /tmp/kong.deb /tmp/kong-deb /tmp/kong-fixed.deb && \
  rm -rf /var/lib/apt/lists/*

# Create symlinks
RUN ln -sf /usr/local/openresty/bin/resty /usr/local/bin/resty && \
  ln -sf /usr/local/openresty/luajit/bin/luajit /usr/local/bin/luajit && \
  ln -sf /usr/local/openresty/luajit/bin/luajit /usr/local/bin/lua && \
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/local/bin/nginx

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

RUN chown kong:0 /usr/local/bin/kong && \
  chown -R kong:0 /usr/local/kong && \
  chown kong:0 /docker-entrypoint.sh

# Final stage: clean runtime image
FROM secure-base AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  zlib1g \
  libyaml-0-2 && \
  rm -rf /var/lib/apt/lists/*

COPY --from=kong-install /usr/local /usr/local
COPY --from=kong-install /etc/kong /etc/kong
COPY --from=kong-install /docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=kong-install /etc/passwd /etc/passwd
COPY --from=kong-install /etc/group /etc/group
COPY --from=kong-install /etc/shadow /etc/shadow

RUN set -ex; \
  arch=$(dpkg --print-architecture); \
  case "${arch}" in \
  amd64) LIB_DIR="x86_64-linux-gnu" ;; \
  arm64) LIB_DIR="aarch64-linux-gnu" ;; \
  *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
  esac; \
  ln -sf /lib/${LIB_DIR}/libz.so.1 /lib/${LIB_DIR}/libz.so && \
  ln -sf /lib/${LIB_DIR}/libz.so.1 /usr/lib/${LIB_DIR}/libz.so

RUN chown kong:0 /usr/local/bin/kong && \
  chown -R kong:0 /usr/local/kong && \
  chown kong:0 /docker-entrypoint.sh && \
  chmod 755 /docker-entrypoint.sh

RUN mkdir -p /usr/local/kong/declarative && \
  chown -R kong:0 /usr/local/kong

EXPOSE 8000 8001 8443 8444

HEALTHCHECK --interval=10s --timeout=10s --retries=10 \
  CMD kong health || exit 1

USER kong
WORKDIR /usr/local/kong

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["kong", "docker-start"]

LABEL maintainer="Kong Docker Maintainers <suriya.ruk@dome.cloud> (@team-gateway-bot)"
LABEL org.opencontainers.image.version="26.04"
LABEL security.patched="true"
LABEL security.patch.date="2026-06-15"
LABEL security.patch.method="base-image-update-with-security-patches"
LABEL kong.version="3.9.2"
LABEL description="Kong Gateway 3.9.2 with security patches applied"
