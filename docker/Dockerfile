# syntax=docker/dockerfile:1.7
#
# Build image for WD My Cloud OS5 app packages (.bin).
# Contains WD's packager (mksapkg-OS5) and what it shells out to.

FROM debian:bookworm-slim

# mksapkg-OS5 links against libxml2 and calls the openssl CLI; curl and
# ca-certificates are for fetching upstream payloads (e.g. Tailscale);
# binutils' readelf is for the ARM alignment check in package.sh.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libxml2 openssl ca-certificates curl binutils \
    && rm -rf /var/lib/apt/lists/*

COPY openssl-legacy.cnf /etc/ssl/openssl-legacy.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf

# WDCommunity/wdpksrc, pinned by commit and verified by hash.
ARG WDPKSRC_COMMIT=1b414413b5acec3e008cf6b6e29d9d6404379b7f
ADD --chmod=755 \
    --checksum=sha256:62340b1d0eb0433fffa7ceb1a5b6d4886e69b93e6e60297b2f984f5f3557e67a \
    https://raw.githubusercontent.com/WDCommunity/wdpksrc/${WDPKSRC_COMMIT}/mksapkg-OS5 \
    /usr/local/bin/mksapkg-OS5

# Fail the image build now, not at packaging time, if Blowfish is unavailable.
RUN echo selftest | openssl bf-cbc -md sha256 -k selftest -out /dev/null 2>/dev/null \
    && echo "openssl bf-cbc: ok"

WORKDIR /work
