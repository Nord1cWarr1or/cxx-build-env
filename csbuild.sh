#!/bin/bash
# csbuild.sh — build CS-ecosystem projects (ReHLDS/ReGameDLL/reapi/AMXX modules/plugins)
# inside the oracle-7 toolchain container, producing binaries on the HOST.
#
# The project directory (local path or cloned from a git URL) is bind-mounted into
# the container; build artifacts appear directly in the mounted directory, then get
# collected into an output folder on the host.
#
# Usage:
#   ./csbuild.sh [options] <path-or-url> [more targets...]
#
# Options:
#   -o, --out <dir>     Base output directory (default: <project>/csbuild-out)
#   -b, --branch <ref>  Branch/tag to clone when the target is a git URL
#   -i, --image <img>   Container image (default: hun1er/oracle-7-cxx-build-env-gnu:latest)
#   -j, --jobs <n>      Parallel build jobs (default: all CPU cores)
#   -m, --mount h:c     Extra bind mount host:container (repeatable)
#   -e, --env K=V       Environment variable for the build container (repeatable),
#                       e.g. -e CXXFLAGS="-g -O0"
#   -t, --target <name> Build a single target (cmake --build --target / make goal)
#       --config <name> Multi-config flavor for preset builds: release (default),
#                       debug, reldebinfo...
#   -c, --clean         Remove the build directory before building
#       --fresh         Re-clone URL targets from scratch
#   -n, --dry-run       Show the detected build recipe and exit
#   -h, --help          Show this help
#   -- <args>           Extra args appended to the inner build command
#                       (e.g. -- -DENABLE_TESTS=ON, -- --sdks=/path)
#
# Examples:
#   ./csbuild.sh /home/user/projects/reapi
#   ./csbuild.sh https://github.com/user/SomeAmxxModule
#   ./csbuild.sh -o /tmp/out . -- -DENABLE_TESTS=ON
#
# Environment:
#   CSBUILD_IMAGE   Same as --image
#   CSBUILD_HOME    Directory for URL clones
#                   (default: ${XDG_CACHE_HOME:-~/.cache}/csbuild/clones)
#
# Requirements: docker, git, GNU coreutils/findutils (Linux out of the box;
# on macOS: brew install coreutils findutils gnu-sed).
set -euo pipefail

export LC_ALL=C

PROGNAME="$(basename "$0")"
readonly PROGNAME
readonly DEFAULT_IMAGE="hun1er/oracle-7-cxx-build-env-gnu:latest"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]:$NC $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]:$NC $1"; }
print_error() { echo -e "${RED}[ERROR]:$NC $1" >&2; }
print_step()  { echo -e "${CYAN}[STEP]:$NC $1" >&2; }

usage() {
    # Print the header comment block (everything before the first non-comment line).
    awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    exit 0
}

IMAGE="${CSBUILD_IMAGE:-$DEFAULT_IMAGE}"
IMAGE_EXPLICIT=0
[[ -n "${CSBUILD_IMAGE:-}" ]] && IMAGE_EXPLICIT=1
CLONE_HOME="${CSBUILD_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/csbuild/clones}"
OUT_BASE=""
BRANCH=""
JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
CLEAN=0
FRESH=0
DRY_RUN=0
EXTRA=()
MOUNTS=()
ENVS=()
TARGET=""
FLAVOR="release"

# ---------------------------------------------------------------------------
# Option parsing: everything after "--" goes to the inner build command.
# ---------------------------------------------------------------------------
parse_options() {
    local targets=()
    local in_extra=0

    while [[ $# -gt 0 ]]; do
        if [[ $in_extra -eq 1 ]]; then
            EXTRA+=("$1"); shift; continue
        fi
        case "$1" in
            --)         in_extra=1; shift ;;
            -o|--out)   OUT_BASE="$2"; shift 2 ;;
            -b|--branch) BRANCH="$2"; shift 2 ;;
            -i|--image) IMAGE="$2"; IMAGE_EXPLICIT=1; shift 2 ;;
            -j|--jobs)  JOBS="$2"; shift 2 ;;
            -m|--mount) MOUNTS+=("$2"); shift 2 ;;
            -e|--env)   ENVS+=("$2"); shift 2 ;;
            -t|--target) TARGET="$2"; shift 2 ;;
            --config)   FLAVOR="$2"; shift 2 ;;
            -c|--clean) CLEAN=1; shift ;;
            --fresh)    FRESH=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -h|--help)  usage ;;
            -*)         print_error "Unknown option: $1"; exit 1 ;;
            *)          targets+=("$1"); shift ;;
        esac
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        print_error "No target specified. Run '$PROGNAME --help'."
        exit 1
    fi
    TARGETS=("${targets[@]}")

    if ! command -v docker >/dev/null 2>&1; then
        print_error "docker is required but was not found in PATH."
        exit 1
    fi
}

is_url() {
    [[ "$1" == http://* || "$1" == https://* || "$1" == git@* || "$1" == ssh://* || "$1" == *.git ]]
}

# Resolve a target (local path or git URL) to an absolute project directory.
# NOTE: this runs under command substitution in build_one(), so all git output
# must go to stderr — stdout carries only the resolved path.
resolve_target() {
    local t="$1"
    if is_url "$t"; then
        local name dest
        name="$(basename "$t" .git)"
        dest="$CLONE_HOME/$name"
        if [[ -d "$dest/.git" ]]; then
            if [[ $FRESH -eq 1 ]]; then
                print_step "Re-cloning $t (fresh)"
                rm -rf "$dest"
                git clone ${BRANCH:+--branch "$BRANCH"} "$t" "$dest" >&2
            else
                print_step "Updating existing clone $dest"
                git -C "$dest" pull --ff-only >&2 \
                    || print_warn "pull failed (diverged?), keeping current state (use --fresh to re-clone)"
            fi
        else
            print_step "Cloning $t -> $dest"
            git clone ${BRANCH:+--branch "$BRANCH"} "$t" "$dest" >&2
        fi
        init_submodules "$dest"
        echo "$dest"
    else
        [[ -d "$t" ]] || { print_error "Not a directory: $t"; exit 1; }
        init_submodules "$t"
        realpath "$t" 2>/dev/null || { cd "$t" && pwd; }
    fi
}

init_submodules() {
    local d="$1"
    if [[ -f "$d/.gitmodules" ]]; then
        git -C "$d" submodule update --init --recursive >&2 \
            || print_warn "git submodule update failed for $d (build may miss SDKs)"
    fi
}

# ---------------------------------------------------------------------------
# Build recipe detection. Echoes an inner bash snippet executed inside the
# container with cwd=/src (the mounted project root). Empty output = unknown.
# ---------------------------------------------------------------------------
detect_recipe() {
    local src="$1" sub tc

    # 1. Project-owned root build.sh (reapi, ReGameDLL_CS, Amxx-Module-CSWM).
    #    Only pass -j= when the script actually consumes it.
    if [[ -f "$src/build.sh" ]]; then
        local jarg=""
        grep -qE '(^|[[:space:]])-j=' "$src/build.sh" && jarg="-j=$JOBS"
        echo "cd /src && bash build.sh $jarg$(quote_extra)"
        return 0
    fi

    # 2. AMBuild (AMBuildScript + configure.py: rsKliPPy modules, many AMXX
    #    modules). Dep-heavy projects (amxmodx) may need -m mounts and extra
    #    args via -- (passed to configure.py).
    if [[ -f "$src/configure.py" && -f "$src/AMBuildScript" ]]; then
        echo "cd /src && mkdir -p build && cd build && python3 ../configure.py$(quote_extra) && ambuild"
        return 0
    fi

    # 3. Distro-specific canonical script (amxx-nova-pc: tools/linux/build.sh,
    #    defaults to Release + ninja, jobs = all cores).
    if [[ -f "$src/tools/linux/build.sh" ]]; then
        echo "cd /src && bash tools/linux/build.sh$(quote_extra)"
        return 0
    fi

    # 4. CMake. Author-faithful: when CMakePresets.json exists, build via the
    #    project's own presets (pick gcc+linux like their CI usually does,
    #    else the first listed preset) — no flags of our own. Otherwise plain
    #    cmake with no build type (ecosystem convention: reapi/ReGameDLL CI and
    #    revoice docs all configure without one). A vendored i686 toolchain
    #    file is passed when the project ships one (that IS author intent).
    #    If configure dies on legacy cmake_minimum_required(), build_one()
    #    retries once with the CMAKE_POLICY_VERSION_MINIMUM env knob.
    if [[ -f "$src/CMakeLists.txt" ]]; then
        tc="$(find_toolchain "$src")"
        if [[ -f "$src/CMakePresets.json" ]]; then
            printf '%s\n' "cd /src && P=\$(cmake --list-presets | sed -n 's/^[[:space:]]*\"\([^\"]*\)\".*\$/\1/p') && SEL=\$(printf '%s\n' \"\$P\" | grep -E 'gcc.*linux|linux.*gcc' | head -n1) ; REL=\$(printf '%s\n' \"\$P\" | grep -E 'gcc.*linux|linux.*gcc' | grep -iE 'release' | head -n1) ; SEL=\${REL:-\${SEL:-\$(printf '%s\n' \"\$P\" | head -n1)}} ; B=\$(cmake --list-presets=build | sed -n 's/^[[:space:]]*\"\([^\"]*\)\".*\$/\1/p') && BSEL=\$(printf '%s\n' \"\$B\" | grep -Fx \"\${SEL}-${FLAVOR}\" | head -n1) ; BSEL=\${BSEL:-\$(printf '%s\n' \"\$B\" | grep -Fx \"\$SEL\" | head -n1)} ; BSEL=\${BSEL:-\$SEL} ; printf 'Using CMake presets: %s / build: %s\n' \"\$SEL\" \"\$BSEL\" >&2 ; cmake --preset \"\$SEL\"$(quote_extra) && cmake --build --preset \"\$BSEL\" --parallel $JOBS${TARGET:+ --target $TARGET}"
        else
            echo "cd /src && cmake -B build -S . ${tc:+-DCMAKE_TOOLCHAIN_FILE=$tc }$(quote_extra) && cmake --build build -j $JOBS${TARGET:+ --target $TARGET}"
        fi
        return 0
    fi

    # 5. Flat-module build script at root (ButtonsManager: Compile.sh,
    #    rehlmaster: compile.sh).
    local script
    for script in Compile.sh compile.sh; do
        if [[ -f "$src/$script" ]]; then
            echo "cd /src && bash $script$(quote_extra)"
            return 0
        fi
    done

    # 6. Root Makefile (metamod-plugin style one-shot: botaim_plugin,
    #    CrossAuth, HTTP-Resources-Manager, ReInfoZone).
    if [[ -f "$src/Makefile" ]]; then
        echo "cd /src && make -j $JOBS${TARGET:+ $TARGET}$(quote_extra)"
        return 0
    fi

    # 7. One level down: Makefile or CMakeLists.txt in a subdirectory
    #    (MatchBot: MatchBot/Makefile).
    local d sub
    for d in "$src"/*/; do
        [[ -d "$d" ]] || continue
        sub="$(basename "$d")"
        case "$sub" in .*|Release|out) continue ;; esac
        if [[ -f "$d/Makefile" ]]; then
            echo "cd /src/$sub && make -j $JOBS${TARGET:+ $TARGET}$(quote_extra)"
            return 0
        fi
        if [[ -f "$d/CMakeLists.txt" ]]; then
            tc="$(find_toolchain "$d")"
            if [[ -f "$d/CMakePresets.json" ]]; then
                printf '%s\n' "cd /src/$sub && P=\$(cmake --list-presets | sed -n 's/^[[:space:]]*\"\([^\"]*\)\".*\$/\1/p') && SEL=\$(printf '%s\n' \"\$P\" | grep -E 'gcc.*linux|linux.*gcc' | head -n1) ; REL=\$(printf '%s\n' \"\$P\" | grep -E 'gcc.*linux|linux.*gcc' | grep -iE 'release' | head -n1) ; SEL=\${REL:-\${SEL:-\$(printf '%s\n' \"\$P\" | head -n1)}} ; B=\$(cmake --list-presets=build | sed -n 's/^[[:space:]]*\"\([^\"]*\)\".*\$/\1/p') && BSEL=\$(printf '%s\n' \"\$B\" | grep -Fx \"\${SEL}-${FLAVOR}\" | head -n1) ; BSEL=\${BSEL:-\$(printf '%s\n' \"\$B\" | grep -Fx \"\$SEL\" | head -n1)} ; BSEL=\${BSEL:-\$SEL} ; printf 'Using CMake presets: %s / build: %s\n' \"\$SEL\" \"\$BSEL\" >&2 ; cmake --preset \"\$SEL\"$(quote_extra) && cmake --build --preset \"\$BSEL\" --parallel $JOBS${TARGET:+ --target $TARGET}"
            else
                echo "cd /src/$sub && cmake -B build -S . ${tc:+-DCMAKE_TOOLCHAIN_FILE=$tc }$(quote_extra) && cmake --build build -j $JOBS${TARGET:+ --target $TARGET}"
            fi
            return 0
        fi
        if [[ -f "$d/build.sh" ]]; then
            echo "cd /src/$sub && bash build.sh$(quote_extra)"
            return 0
        fi
    done

    # 8. Two levels down: SDK-layout projects (monstermod-redo: src/dlls/Makefile).
    for m in "$src"/*/*/Makefile; do
        [[ -f "$m" ]] || continue
        sub="${m#"$src/"}"
        sub="${sub%/Makefile}"
        echo "cd /src/$sub && make -j $JOBS${TARGET:+ $TARGET}$(quote_extra)"
        return 0
    done

    return 1
}

# First i686 toolchain file (root, then one level down), as a /src-relative path.
find_toolchain() {
    local base="$1" hit
    hit="$(find "$base" -maxdepth 2 -name '*i686*.cmake' -type f 2>/dev/null | sort | head -n1)"
    [[ -n "$hit" ]] && echo "${hit#"$base"/}"
}

# Space-joined, shell-quoted extra args for embedding into the inner snippet.
quote_extra() {
    local a out=""
    for a in "${EXTRA[@]+${EXTRA[@]}}"; do
        out+=" $(printf '%q' "$a")"
    done
    echo "$out"
}

describe_unknown() {
    local src="$1" found=() hit
    [[ -f "$src/CMakePresets.json" ]] && found+=("CMakePresets.json")
    hit="$(find "$src" -maxdepth 1 -name '*.sln' 2>/dev/null | head -n1)"
    [[ -n "$hit" ]] && found+=("MSVC .sln (no Linux build system)")
    hit="$(find "$src" -maxdepth 3 -name '*.sma' 2>/dev/null | head -n1)"
    [[ -n "$hit" ]] && found+=("Pawn sources (*.sma — compile with spcomp/amxxpc, not shipped in the image)")
    [[ -f "$src/Makefile" ]] && found+=("root Makefile")
    if [[ ${#found[@]} -gt 0 ]]; then
        printf 'found: %s\n' "${found[*]}"
    else
        printf 'no recognized build files\n'
    fi
}

# ---------------------------------------------------------------------------
# Container execution
# ---------------------------------------------------------------------------
# Toolchain-era auto-selection. When the project's own CI declares a container
# we ship a matching image for, build there: the authors' CI defines the
# toolchain their flags expect (e.g. ReGameDLL/reapi pin debian:11-slim; their
# -fno-plt on i386 needs old GCC, GCC >= 14 emits relocations modern binutils
# rejects). An explicit --image / CSBUILD_IMAGE always wins.
pick_image() {
    local src="$1" line
    [[ $IMAGE_EXPLICIT -eq 1 ]] && return 0
    while IFS= read -r line; do
        line="${line#*:}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%\"}"; line="${line#\"}"
        case "$line" in
            debian:11-slim|debian:bullseye*|debian:eol-11*)
                IMAGE="hun1er/debian-11-cxx-build-env-gnu:latest"
                print_info "Project CI pins container '$line' — using authors' era image: $IMAGE"
                return 0
                ;;
        esac
    done < <(grep -rhoE 'container[a-z_]*:[[:space:]]*[^[:space:]]+' "$src/.github/workflows" 2>/dev/null)
}

ensure_image() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        print_step "Image $IMAGE not found locally, pulling"
        docker pull "$IMAGE"
    fi
}

run_in_container() {
    local src="$1" inner="$2" log="$3" m
    local -a margs=()
    for m in "${MOUNTS[@]+${MOUNTS[@]}}"; do
        margs+=(-v "$m")
    done
    local -a eargs=()
    for e in "${ENVS[@]+${ENVS[@]}}"; do
        eargs+=(-e "$e")
    done
    docker run --rm -t \
        -u "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        "${eargs[@]}" \
        "${margs[@]}" \
        -v "$src":/src \
        -w /src \
        "$IMAGE" bash -ec "$inner" 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Artifact collection: files created during this build that look like binaries.
# Newline-delimited find output (portable); project paths with newlines in
# their names are not a thing in this ecosystem.
# ---------------------------------------------------------------------------
collect_artifacts() {
    local src="$1" out="$2" marker="$3" f rel dest count=0

    mkdir -p "$out"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *.so|*.so.*|*.amxx) ;;
            *)
                # Non-.so/.amxx: keep only if it is an ELF executable.
                command -v file >/dev/null 2>&1 || continue
                file -b "$f" 2>/dev/null | grep -q 'ELF' || continue
                ;;
        esac
        rel="${f#"$src"/}"
        dest="$out/$rel"
        mkdir -p "$(dirname "$dest")"
        cp -f "$f" "$dest"
        print_info "artifact: $rel ($(du -h "$f" | cut -f1)) -> $dest"
        count=$((count + 1))
    done < <(
        {
            find "$src" -name .git -prune -o -name csbuild-out -prune -o -name CMakeFiles -prune -o -name .ambuild2 -prune -o -type f -newer "$marker" \
                \( -name '*.so' -o -name '*.so.*' -o -name '*.amxx' \) -print
            if command -v file >/dev/null 2>&1; then
                find "$src" -name .git -prune -o -name csbuild-out -prune -o -name CMakeFiles -prune -o -name .ambuild2 -prune -o -type f -executable -newer "$marker" -print
            fi
        } | sort -u
    )

    if [[ $count -eq 0 ]]; then
        print_warn "No new artifacts found (some projects output into unusual paths; check build log)"
    fi
}

build_one() {
    local target="$1" src inner marker out

    src="$(resolve_target "$target")" || return 1
    print_step "Project root: $src"

    if [[ $CLEAN -eq 1 && -d "$src/build" ]]; then
        print_step "Removing $src/build"
        rm -rf "$src/build"
    fi

    inner="$(detect_recipe "$src")" || {
        print_error "Cannot detect a build system in $src ($(describe_unknown "$src"))"
        return 1
    }

    pick_image "$src"
    print_info "Image: $IMAGE"
    print_info "Recipe: $inner"
    if [[ $DRY_RUN -eq 1 ]]; then
        return 0
    fi

    # A stale CMake cache from a different toolchain image (bind-mounted build
    # dir survives image switches) produces phantom link errors — wipe it.
    local stamp
    stamp="$src/.csbuild-image"
    if [[ -f "$stamp" && "$(cat "$stamp")" != "$IMAGE" ]]; then
        print_warn "Toolchain image changed (was '$(cat "$stamp")') — removing stale build dirs"
        rm -rf "$src/build" "$src/out"
    fi

    ensure_image
    print_step "Building inside $IMAGE"
    marker="$src/.csbuild-marker"
    : > "$marker"
    local log
    log="/tmp/csbuild-$(basename "$src").log"

    local built=0 attempt_inner="$inner"
    if run_in_container "$src" "$attempt_inner" "$log"; then
        built=1
    elif grep -qiE 'Compatibility with CMake < 3\.5|cmake_minimum_required.*(remove|raise|policy)|CMAKE_POLICY_VERSION_MINIMUM' "$log" \
         && grep -q '^cd /src' <<< "$inner"; then
        # CMAKE_POLICY_VERSION_MINIMUM is a CMake compatibility env knob,
        # it does not alter any author compiler/linker flags.
        print_warn "configure failed on legacy cmake_minimum_required(); retrying with CMAKE_POLICY_VERSION_MINIMUM=3.5 env"
        attempt_inner="export CMAKE_POLICY_VERSION_MINIMUM=3.5; $inner"
        if run_in_container "$src" "$attempt_inner" "$log"; then
            built=1
        fi
    fi

    # The CS 1.6 ecosystem spans two toolchain eras; projects with legacy
    # author flags (old AMTL + -Werror, i386 -fno-plt, icc-era sources) often
    # fail only on the modern GCC. Before giving up, retry once in the
    # authors' era image. Explicit --image / CSBUILD_IMAGE is never overridden.
    if [[ $built -eq 0 && "$IMAGE" == "$DEFAULT_IMAGE" && $IMAGE_EXPLICIT -eq 0 ]]; then
        print_warn "Build failed on the modern toolchain — retrying with the authors' era image (debian-11, GCC 10.2)"
        IMAGE="hun1er/debian-11-cxx-build-env-gnu:latest"
        rm -rf "$src/build" "$src/out"
        ensure_image
        print_step "Building inside $IMAGE"
        attempt_inner="export CMAKE_POLICY_VERSION_MINIMUM=3.5; $inner"
        if run_in_container "$src" "$attempt_inner" "$log"; then
            built=1
        fi
    fi

    if [[ $built -eq 1 ]]; then
        printf '%s\n' "$IMAGE" > "$stamp"
    else
        rm -f "$marker"
        return 1
    fi

    if [[ -n "$OUT_BASE" ]]; then
        out="$OUT_BASE/$(basename "$src")"
    else
        out="$src/csbuild-out"
    fi
    collect_artifacts "$src" "$out" "$marker"
    rm -f "$marker"
    print_info "Done: $(basename "$src")"
}

main() {
    parse_options "$@"
    local t rc=0
    for t in "${TARGETS[@]}"; do
        echo -e "${CYAN}===================================================================$NC"
        if ! build_one "$t"; then
            print_error "Target failed: $t"
            rc=1
        fi
    done
    exit "$rc"
}

main "$@"
