#!/usr/bin/env bash
#
# mayhem/build.sh — build patchelf's fuzz harness (sanitized) and its own test suite (normal flags).
# Runs inside the commit image as `mayhem` in /mayhem; re-runnable and air-gapped (no fetches).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Fuzz harness. The harness #includes src/patchelf.cc into its own TU (as upstream's fuzz/fuzz.cc
#    does), so the whole project is compiled with the sanitizers + libFuzzer coverage + DWARF 3.
FUZZ_CXXFLAGS="-std=c++17 -O1 -DNDEBUG -D_FILE_OFFSET_BITS=64 -I$SRC/src"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# LeakSanitizer off at build time (fleet policy); ASan + UBSan stay fully active.
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"
# The run-once driver is C; compile it as C so the harness's extern "C" entry point links.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_CXXFLAGS $LIB_FUZZING_ENGINE \
    mayhem/patchelf_fuzz/fuzz.cc "$OBJ/lsan_off.o" -o "$SRC/patchelf_fuzz"
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_CXXFLAGS \
    mayhem/patchelf_fuzz/fuzz.cc "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" -o "$SRC/patchelf_fuzz-standalone"

# 2) patchelf's own test suite, with the project's NORMAL flags (no sanitizers, no -gdwarf-3):
#    autotools in-tree (every generated file is covered by upstream's .gitignore), then build the
#    `check_PROGRAMS` fixtures without running them. mayhem/test.sh only RUNS them.
[ -x ./configure ] || ./bootstrap.sh
if [ ! -f Makefile ]; then
    env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS ./configure CC="$CC" CXX="$CXX"
fi
env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS"
env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" check TESTS=
