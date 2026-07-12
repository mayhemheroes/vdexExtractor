#!/usr/bin/env bash
#
# mayhem/build.sh — build vdexExtractor's fuzz harness + a clean functional-test binary.
#
# Layout produced:
#   /mayhem/vdexExtractor              libFuzzer harness (ASan+UBSan, DWARF-3) — the Mayhem target
#   /mayhem/vdexExtractor-standalone   run-once reproducer (same harness, no libFuzzer runtime)
#   /mayhem/bin/vdexExtractor          upstream CLI, NORMAL flags — driven by mayhem/test.sh
set -euo pipefail

# clang rejects an empty SOURCE_DATE_EPOCH.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS STANDALONE_FUZZ_MAIN

cd "$SRC"

# Common compile flags for the project sources (C11 + _GNU_SOURCE, matching src/Makefile).
# -Werror is intentionally dropped: upstream builds with gcc, and clang emits a few additional
# (benign) warnings that -Werror would turn into hard failures. VERSION is stubbed so the build
# doesn't depend on git metadata being present.
PROJ_CFLAGS="-std=c11 -D_GNU_SOURCE -DVERSION=\"mayhem-fuzz\""

# ---- 1) Instrumented project library (everything EXCEPT the CLI main) ---------------
# Build the FUZZED CODE with $SANITIZER_FLAGS + $DEBUG_FLAGS so ASan/UBSan see the parser/backend,
# not just the harness, and the binary carries DWARF < 4 symbols.
OBJDIR=/tmp/vdex_obj
rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"
mapfile -t PROJ_SRCS < <(find src -name '*.c' ! -name 'vdexExtractor.c' | sort)
for f in "${PROJ_SRCS[@]}"; do
  obj="$OBJDIR/$(echo "$f" | tr '/' '_').o"
  # shellcheck disable=SC2086
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $PROJ_CFLAGS -c "$f" -o "$obj"
done
llvm-ar rcs "$OBJDIR/libvdex.a" "$OBJDIR"/*.o

# ---- 2) Harness: fuzzer binary + standalone reproducer ------------------------------
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $PROJ_CFLAGS $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_vdex.c" "$OBJDIR/libvdex.a" -lz -lm \
    -o /mayhem/vdexExtractor
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $PROJ_CFLAGS \
    "$STANDALONE_FUZZ_MAIN" "$SRC/mayhem/fuzz_vdex.c" "$OBJDIR/libvdex.a" -lz -lm \
    -o /mayhem/vdexExtractor-standalone

# ---- 3) Functional-test binary: upstream CLI with NORMAL flags ----------------------
# A clean, independent (non-sanitized) build of the whole tool — this is what mayhem/test.sh runs
# as its known-answer oracle. $COVERAGE_FLAGS (empty by default) instruments only this build.
mkdir -p /mayhem/bin
mapfile -t ALL_SRCS < <(find src -name '*.c' | sort)
# shellcheck disable=SC2086
$CC -O2 $PROJ_CFLAGS $COVERAGE_FLAGS "${ALL_SRCS[@]}" -lz -lm -o /mayhem/bin/vdexExtractor

echo "build.sh: done — targets: /mayhem/vdexExtractor (+ -standalone), oracle: /mayhem/bin/vdexExtractor"
