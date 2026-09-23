#
# Debian 11 (bullseye) toolchain image — the "authors' era" build environment
# for the CS 1.6 ecosystem.
#
# WHY: several projects pin author flags that only old toolchains honor:
#   - ReGameDLL/reapi CI builds inside debian:11-slim (gcc 10.2 / binutils 2.35)
#   - AlliedModders projects build in debian-10 containers (gcc 8.3)
# GCC >= ~14 emits direct GOT32X relocations for i386 -fno-plt code that
# modern binutils rejects for shared objects (verified with 2.40 and 2.47),
# so those projects must be built with an old GCC. This image provides it.
#
# Debian 11 is EOL (2026-08-31): apt sources are pinned to a
# snapshot.debian.org timestamp matching the Docker Hub base image build date,
# so the installed package versions are consistent with the base layer.
# Bump SNAPSHOT_TS when the debian:11-slim base image is refreshed.
#
FROM debian:11-slim

# Base image build date (docker image inspect debian:11-slim --format '{{.Created}}')
ARG SNAPSHOT_TS="20260824T000000Z"

RUN printf '%s\n' \
        "deb http://snapshot.debian.org/archive/debian/${SNAPSHOT_TS} bullseye main" \
        "deb http://snapshot.debian.org/archive/debian-security/${SNAPSHOT_TS} bullseye-security main" \
        > /etc/apt/sources.list && \
    dpkg --add-architecture i386 && \
    apt-get update -o Acquire::Retries=5 -o Acquire::Check-Valid-Until=false && \
    apt-get install -y --no-install-recommends \
        -o Acquire::Retries=5 -o Acquire::Check-Valid-Until=false \
        gcc-multilib g++-multilib \
        build-essential \
        libc6-dev libc6-dev-i386 \
        git cmake rsync make \
        nasm \
        python3 python3-pip python3-setuptools \
        ca-certificates wget curl unzip zip xz-utils \
        g++ gcc && \
    # ambuild is not on PyPI — AlliedModders installs it from git
    # (same approach as scripts/install_ambuild.sh)
    git clone --depth 1 https://github.com/alliedmodders/ambuild /tmp/ambuild && \
    pip3 install --no-cache-dir /tmp/ambuild && \
    rm -rf /tmp/ambuild && \
    git config --global --add safe.directory '*' && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
