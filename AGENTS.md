# AGENTS.md

Docker images for C/C++ toolchains (32/64-bit multilib), based on Oracle Linux 7 (glibc 2.17) and Ubuntu 24.04. No app code, no tests, no CI — verification means building images.

## Building

- `build.sh` is the only entry point. **Run it from the repo root** — build context is `.` and Dockerfiles `COPY "../scripts"`, so building from a distro subdirectory fails.
- `./build.sh -d <oracle-7|ubuntu-24.04> -c <gnu|clang|all> [-t tag]` (default compiler: `all`; `gcc` is normalized to `gnu`). Default tags: `hun1er/<distro>-cxx-build-env-<compiler>`.
- `csbuild.sh` builds third-party CS-ecosystem projects (local path or git URL) inside the toolchain images via bind mount, with build-system autodetection (build.sh → AMBuild → tools/linux/build.sh → CMake presets/plain → Compile.sh/compile.sh → root Makefile → subdir Makefile → two-level `*/*/Makefile`); artifacts are collected to `<project>/csbuild-out`. Run it from any directory; clones land in `${CSBUILD_HOME:-${XDG_CACHE_HOME:-~/.cache}/csbuild/clones}`.
- csbuild era handling: on a build failure with the default modern image it automatically retries once in debian-11 (authors' era; the CS ecosystem spans GCC 8-10 code that modern GCC breaks: old AMTL + `-Werror`, i386 `-fno-plt` GOT32X relocations). `.csbuild-image` stamp wipes stale build dirs on image switch (CMakeCache poisons across toolchains). An explicit `--image`/`CSBUILD_IMAGE` disables the auto-retry.
- Known limits (batch-verified 2026-09): icc-only projects (ReInfoZone: icpc + opaque-enum extension) are unsupportable in any image; some upstream repos are simply broken (webserver_amxx includes a header never committed). AMBuild dep-heavy projects (amxmodx) need `-m` SDK mounts + `-- --metamod=... --hlsdk=...`.
- **Image dependency order:**
  - ubuntu-24.04: build `gnu` **before** `clang` — `Dockerfile.clang` is `FROM hun1er/ubuntu-24.04-cxx-build-env-gnu`.
  - oracle-7: stage 1 (builder) is `FROM hun1er/oracle-7-cxx-build-env-gnu` — it **pulls the published image from Docker Hub**. A from-scratch oracle build (or changing the base toolchain) depends on the already-published image.
- Oracle build compiles GCC from source (`--disable-bootstrap`) — expect a long build. Ubuntu installs the distro PPA package.
- Docker builds work on **both** BuildKit and the legacy builder: `build_image()` detects the legacy `forbidden path outside the build context` error and retries with a temp context-relative Dockerfile. Chained ARG defaults (e.g. `GCC_PREFIX="$BINUTILS_PREFIX"`) do not expand on the legacy builder — `oracle-7/Dockerfile.gnu` deliberately inlines them as literals; keep them that way.
- **Script exec bits must stay 100755 in git** (`scripts/**/*.sh`, `build.sh`). They were once committed as 100644 (invisible on a machine with `core.filemode=false`), which broke every fresh clone at the `./install_*.sh` step inside the image build.
- Tool versions in `build.sh` are env-overridable without editing: `BINUTILS_VERSION=2.40 ./build.sh -d oracle-7 -c gnu -t my-tag`.
- **Two toolchain eras, both first-class**: modern C++ (nova-pc, rehlds-m — C++23) needs oracle-7's GCC 15/16; legacy author flags (ReGameDLL's `-fno-plt` on i386 — GCC >= 14 emits GOT32X relocations binutils 2.40/2.47 both reject; AMXX-era `-Werror` + old AMTL) need debian-11's GCC 10.2. One image cannot cover both. `csbuild.sh` auto-selects debian-11 when the project's CI declares `container: debian:11-slim` (see `pick_image`); override via `--image`/`CSBUILD_IMAGE`.
- debian-11 image pins apt to snapshot.debian.org at the base image build date (`SNAPSHOT_TS` ARG — bump it when `debian:11-slim` is refreshed, check with `docker image inspect debian:11-slim --format '{{.Created}}'`; a newer base + older snapshot = libc version conflicts). ambuild installs from git, not PyPI (it's not published there).
- Image-build landmines fixed for public builds: binutils >= 2.39 needs `--disable-gprofng` (bison missing) and `MAKEINFO=true` (no texinfo) — both already in `scripts/install_binutils.sh`; `install_gcc.sh` skips wget when `gcc.tar.gz` already exists in `/tmp` (allows COPY'ing a pre-downloaded tarball).
- **Gold linker**: removed from binutils in 2.44, so the pinned 2.47 build has no gold; the EL7 system gold (2.27) predates `--warn-drop-version`. `scripts/install_gold.sh` side-builds gold from the last gold-capable release (2.43, `GOLD_VERSION`) and installs only `ld.gold` next to ld.bfd — `-fuse-ld=gold` resolves there before the system linker. Projects relying on the fallback (rehlds-m, AdminsKit author defaults) need it.
- **Runtime smoke limitation**: oracle-7 targets glibc 2.17 by design, so binaries built FOR modern glibc (e.g. rehlds-m unittest presets) can be linked there but not executed — interactive runtime smokes need the ubuntu-24.04 image (glibc 2.39). Unit tests with self-contained libs run fine in oracle-7.
- The csbuild era-retry (modern fail → debian-11) can mask oracle-7-specific link errors: a project may "pass" via fallback while a direct `cmake` in oracle-7 still fails. When debugging image issues, bypass the fallback with explicit `--image`.

## Versions

- All tool versions are `readonly` vars at the **top of `build.sh`**, passed as `--build-arg`; Dockerfiles fail fast on missing ARGs (`: "${VAR:?}"`). Bump versions there, never in Dockerfiles or `scripts/`.
- Unpinned exceptions: Ninja is built from git branch `release` (no version arg), Mold defaults to `${MOLD_VERSION:-stable}`, IWYU tracks the `clang_$CLANG_VERSION` branch, AMBuild installs via pip.
- **GCC versioning is asymmetric**: Ubuntu uses the `ubuntu-toolchain-r/test` PPA package (`ARG GNU_VERSION="16"` default inside `ubuntu-24.04/Dockerfile.gnu`, not passed by build.sh); oracle-7 builds from source using `GCC_VERSION` (full x.y.z) from build.sh. Bumping one does not bump the other — see the two most recent commits.
- devtoolset version (`16`) is hardcoded in `oracle-7/Dockerfile.gnu` (`BUILDER_DEVTOOLSET_VERSION` / `RUNTIME_DEVTOOLSET_VERSION`), independent of `GCC_VERSION`.

## Layout

- `scripts/install_*.sh` run **inside the container** from `/tmp` and take versions from env (Dockerfile ARGs).
- `scripts/<distro>/system_cleanup.sh` per distro; `scripts/oracle/entrypoint.sh` enables `rh-python38` + devtoolset, then `exec "$@"`.

## Conventions

- Commits: lowercase imperative, e.g. `Bump OpenSSL version to 3.6.4`; distro-specific changes get a dash-free prefix: `oracle7: Bump GCC version to 16.2.0`, `ubuntu24: ...`.
- The README version table is informational and lags; `build.sh` is the source of truth.
- LF endings enforced via `.gitattributes`; `.editorconfig`: spaces (4-wide, 2 for JSON/YAML), 120-col guideline.
