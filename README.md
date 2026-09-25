# cxx-build-env

**English** | **[Русский](https://github.com/Nord1cWarr1or/cxx-build-env/blob/main/README.ru.md)**

Docker images for building 32-bit and 64-bit C/C++ software, plus `csbuild.sh` — a runner that compiles third-party CS 1.6 projects (ReGameDLL, reapi, AMXX modules) inside those images with each project's own build system and flags, and lands the binaries on your host, not in the container.

## Images

| Distribution | glibc | GCC | Binutils | CMake | Extras |
|--------------|-------|-----|----------|-------|--------|
| **Oracle Linux 7** | 2.17 | 16.2.0 | 2.47 + gold 2.43 | 3.31.12 | Make 4.4.1, Ninja, Mold, NASM 3.02, OpenSSL 3.6.4, Go 1.27.1, Cppcheck 2.21.0, AMBuild |
| **Debian 11** | 2.31 | 10.2.1 | 2.35.2 | 3.18.4 | NASM 2.15, AMBuild, Python 3 |
| **Ubuntu 24.04** | 2.39 | 16.0.1 | 2.47 | 3.31.12 | Make 4.4.1, Ninja, Mold, NASM 3.02, OpenSSL 3.6.4, Go 1.27.1, Cppcheck 2.21.0, AMBuild; Clang 20.1.8 and IWYU in the `clang` image |

The CS 1.6 ecosystem spans two toolchain eras, and one compiler cannot cover both:

- **Oracle Linux 7** (GCC 16.2) builds modern C++ (rehlds-m, amxx-nova-pc) and produces binaries that run on old glibc 2.17 servers.
- **Debian 11** (GCC 10.2) exists because several projects pin author flags that only old GCC honors. ReGameDLL's `-fno-plt` on i386 makes GCC 14+ emit GOT32X relocations that binutils rejects (verified with 2.40 and 2.47); AMXX-era modules with old AMTL and `-Werror` die on new compilers the same way.

Known unsupportable cases, stated plainly: icc-only builds (ReInfoZone hardcodes `/opt/intel/bin/icpc`), sources broken upstream, and MSVC-only layouts that link against a stack of unvendored repositories.

## Requirements

- Docker. Image builds work on both BuildKit and the legacy builder (`build.sh` retries with a context-relative Dockerfile when the legacy one rejects `COPY "../scripts"`).
- For `csbuild.sh`: `git` and GNU coreutils/findutils. On macOS: `brew install coreutils findutils gnu-sed`.

## Installation

```bash
git clone https://github.com/hun1er/cxx-build-env.git
cd cxx-build-env
```

Nothing else to install — `build.sh` and `csbuild.sh` run from the repository, and images are pulled automatically on first use.

## Usage

### Building images

```bash
./build.sh -d <oracle-7|debian-11|ubuntu-24.04> -c <gnu|clang|all> [-t tag]
```

Default compiler: `all` (everything the distro supports; `gcc` is accepted as an alias of `gnu`). Default tags: `hun1er/<distro>-cxx-build-env-<compiler>`.

| Option | Description |
|--------|-------------|
| `-d, --distro <name>` | Target distribution: `oracle-7`, `debian-11`, `ubuntu-24.04` |
| `-c, --compiler <name>` | `gnu`, `clang` or `all` (default) |
| `-t, --tag <name>` | Custom image tag |
| `-h, --help` | Help |

The build order matters. The Ubuntu `clang` image is based on `hun1er/ubuntu-24.04-cxx-build-env-gnu`, so build `gnu` first. The Oracle Linux 7 builder stage is based on the published `hun1er/oracle-7-cxx-build-env-gnu` image. The Oracle build compiles GCC from source — expect it to take a while.

Tool versions live at the top of `build.sh` as environment-overridable variables — no file editing needed:

```bash
BINUTILS_VERSION=2.40 ./build.sh -d oracle-7 -c gnu -t my-tag
```

Variables: `BINUTILS_VERSION`, `CLANG_VERSION`, `CMAKE_VERSION`, `CPPCHECK_VERSION`, `GCC_VERSION`, `MAKE_VERSION`, `NASM_VERSION`, `GOLANG_VERSION`, `OPENSSL_VERSION`.

### Building third-party projects

`csbuild.sh` takes a local path or a git URL, mounts the project into a toolchain image, detects the build system and collects binaries into `<project>/csbuild-out`. Detection order: project `build.sh` → AMBuild (`configure.py` + `AMBuildScript`) → `tools/linux/build.sh` → CMake (presets when present, otherwise plain) → `Compile.sh`/`compile.sh` → Makefile at the root, one level down, or two levels down.

```bash
./csbuild.sh /path/to/project
./csbuild.sh https://github.com/Nord1cWarr1or/MatchBot
```

| Option | Description |
|--------|-------------|
| `-o, --out <dir>` | Base output directory (default: `<project>/csbuild-out`) |
| `-b, --branch <ref>` | Branch/tag for git URL targets |
| `-i, --image <img>` | Container image (default: `hun1er/oracle-7-cxx-build-env-gnu:latest`) |
| `-j, --jobs <n>` | Parallel jobs (default: all CPU cores) |
| `-m, --mount <h:c>` | Extra bind mount, host:container (repeatable) |
| `-e, --env K=V` | Environment variable for the build container (repeatable) |
| `-t, --target <name>` | Build a single target (`cmake --build --target` / make goal) |
| `--config <name>` | Multi-config flavor for CMake preset builds: `release` (default), `debug`, `reldebinfo`… — picks the matching build preset (rehlds-m: `ninja-gcc-linux-reldebinfo`) |
| `-c, --clean` | Remove the build directory before building |
| `--fresh` | Re-clone URL targets from scratch |
| `-n, --dry-run` | Print the detected recipe and exit |
| `-- <args>` | Extra arguments appended to the inner build command |

The toolchain era is picked automatically. If the project's CI declares `container: debian:11-slim` (ReGameDLL and reapi do), the Debian 11 image is used. A build that fails on the modern toolchain is retried once in the Debian 11 image before giving up; an explicit `--image` or `CSBUILD_IMAGE` disables both behaviors.

Projects that expect sibling SDK directories (amxmodx-style) take a mount plus passthrough arguments:

```bash
git clone https://github.com/alliedmodders/metamod-hl1 metamod-am
git clone https://github.com/alliedmodders/hlsdk hlsdk
./csbuild.sh -m $PWD:/deps <path/to/project> -- --metamod=/deps/metamod-am --hlsdk=/deps/hlsdk
```

Environment variables: `CSBUILD_IMAGE` (same as `--image`), `CSBUILD_HOME` (clone directory, default `${XDG_CACHE_HOME:-~/.cache}/csbuild/clones`).

Custom build flags go through `--` — the arguments land in the configure command (`cmake -DCMAKE_BUILD_TYPE=Debug`, `make CXXFLAGS=-g`, AMBuild `configure.py` options). `-e` injects environment variables (`CXXFLAGS`, `CFLAGS`, `LDFLAGS`), `-t` restricts the build to one target.

Batch-tested against 22 ecosystem projects: 18 build end-to-end. The remaining four are unsupportable by design — an icc-only toolchain (ReInfoZone), sources broken upstream (webserver_amxx, rezombie), and an MSVC-only layout linking against unvendored repositories (BMOD).

## Prebuilt images

- [hun1er/oracle-7-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/oracle-7-cxx-build-env-gnu)
- [hun1er/debian-11-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/debian-11-cxx-build-env-gnu)
- [hun1er/ubuntu-24.04-cxx-build-env-gnu](https://hub.docker.com/repository/docker/hun1er/ubuntu-24.04-cxx-build-env-gnu) and [clang](https://hub.docker.com/repository/docker/hun1er/ubuntu-24.04-cxx-build-env-clang)

## License

This project is licensed under the [MIT License](LICENSE).

Third-party software ships under its own licenses: Oracle Linux under the [Oracle Linux EULA](https://oss.oracle.com/ol7/EULA), GCC under [GNU GPL](https://gcc.gnu.org/onlinedocs/gcc/Copying.html), Clang/LLVM under the [Apache 2.0 License with LLVM Exceptions](https://llvm.org/docs/DeveloperPolicy.html).
