#!/usr/bin/env bash
#
# mayhem/test.sh — RUN patchelf's own functional suite (built by mayhem/build.sh): the autotools
# `make check` over tests/*.sh (each asserts patchelf's output / the rewritten binary's behaviour),
# plus direct known-answer probes of the patchelf binary. exit 0 = pass. Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PATCHELF="$SRC/src/patchelf"
for f in "$PATCHELF" tests/main tests/simple tests/libfoo.so; do
  [ -x "$f" ] || { echo "missing $f — mayhem/build.sh did not build it" >&2; emit_ctrf patchelf-make-check 0 1 0; exit 1; }
done

# 1) upstream's suite. Parse automake's own summary; a neutered patchelf makes these scripts fail.
out="$(make -C tests check 2>&1)"; echo "$out" | tail -n 25
num() { printf '%s\n' "$out" | sed -n "s/^# $1: *\([0-9][0-9]*\)\$/\1/p" | tail -n1; }
total="$(num TOTAL)"; pass="$(num PASS)"; skip="$(num SKIP)"; fail="$(num FAIL)"; xfail="$(num XFAIL)"; xpass="$(num XPASS)"; err="$(num ERROR)"
passed=$(( ${pass:-0} + ${xfail:-0} )); failed=$(( ${fail:-0} + ${xpass:-0} + ${err:-0} )); skipped=${skip:-0}
if [ "${total:-0}" -lt 60 ]; then
  echo "make check ran only ${total:-0} tests (expected >= 60)" >&2; failed=$(( failed + 1 ))
fi

# 2) known-answer probes: compare patchelf's output to independent readelf output / exact strings.
kat() { # name expected actual
  if [ -n "$3" ] && [ "$2" = "$3" ]; then passed=$((passed+1)); echo "KAT ok: $1"
  else failed=$((failed+1)); echo "KAT FAIL: $1: expected '$2' got '$3'" >&2; fi
}
W="$(mktemp -d "${TMPDIR:-/tmp}/patchelf-kat.XXXXXX")"; trap 'rm -rf "$W"' EXIT
kat version "patchelf $(cat "$SRC/version")" "$("$PATCHELF" --version)"
kat interpreter \
  "$(readelf -l tests/simple | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')" \
  "$("$PATCHELF" --print-interpreter tests/simple)"
cp tests/main "$W/main"
"$PATCHELF" --set-rpath /kat/one:/kat/two "$W/main"
kat set-rpath /kat/one:/kat/two "$("$PATCHELF" --print-rpath "$W/main")"
kat rpath-readelf /kat/one:/kat/two \
  "$(readelf -d "$W/main" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p; s/.*(RPATH).*\[\(.*\)\]/\1/p' | head -n1)"
"$PATCHELF" --add-needed libkat.so.9 "$W/main"
kat needed "libkat.so.9" "$("$PATCHELF" --print-needed "$W/main" | grep -x libkat.so.9)"
cp tests/libfoo.so "$W/libfoo.so"
"$PATCHELF" --set-soname libkat-soname.so "$W/libfoo.so"
kat soname libkat-soname.so "$("$PATCHELF" --print-soname "$W/libfoo.so")"

emit_ctrf patchelf-make-check "$passed" "$failed" "$skipped"
