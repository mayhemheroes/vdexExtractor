#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for vdexExtractor.
#
# Upstream ships NO test suite (no `make check`/ctest/unit dir — verified). This is therefore a
# genuine BEHAVIORAL known-answer oracle over the tool's version-detection code path: the VDEX
# magic + version bytes uniquely determine the reported Android API level (vdexApi_printApiLevel:
# 006->API-26, 010->API-27, 019->API-28, 021->API-29; an unknown version is rejected). We feed the
# CLI (built by build.sh with the project's NORMAL flags) crafted VDEX headers and assert the exact
# API string it prints — so a PATCH that neuters the parser (or makes the program exit(0) without
# doing the work) produces the wrong output / no output and FAILS this oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN=/mayhem/bin/vdexExtractor
if [ ! -x "$BIN" ]; then
  echo "test.sh: $BIN not found — build.sh must build it first" >&2
  emit_ctrf "vdex-getapi-kat" 0 1
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a crafted VDEX header (magic 'vdex' + version bytes), zero-padded to 64 bytes.
mk() { printf "$2" > "$WORK/$1"; truncate -s 64 "$WORK/$1"; }
mk v006.vdex '\166\144\145\170\060\060\066\000'                       # "vdex" "006\0"
mk v010.vdex '\166\144\145\170\060\061\060\000'                       # "vdex" "010\0"
mk v019.vdex '\166\144\145\170\060\061\071\000\060\060\060\000'       # "vdex" "019\0" "000\0"
mk v021.vdex '\166\144\145\170\060\062\061\000\060\060\060\000'       # "vdex" "021\0" "000\0"
mk vbad.vdex '\166\144\145\170\071\071\071\000'                       # "vdex" "999\0" (unsupported)

passed=0; failed=0

# Positive known-answer cases: correct version detection -> exact API string + exit 0.
check_api() {
  local file="$1" want="$2" out rc
  out="$("$BIN" --get-api -i "$WORK/$file" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qx "$want"; then
    echo "PASS $file -> $want"; passed=$((passed+1))
  else
    echo "FAIL $file: expected '$want' (rc 0), got '$out' (rc $rc)"; failed=$((failed+1))
  fi
}
check_api v006.vdex API-26
check_api v010.vdex API-27
check_api v019.vdex API-28
check_api v021.vdex API-29

# Negative case: an unsupported version must be REJECTED (non-zero exit, no API line).
out="$("$BIN" --get-api -i "$WORK/vbad.vdex" 2>/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^API-'; then
  echo "PASS vbad.vdex -> rejected"; passed=$((passed+1))
else
  echo "FAIL vbad.vdex: expected rejection, got '$out' (rc $rc)"; failed=$((failed+1))
fi

emit_ctrf "vdex-getapi-kat" "$passed" "$failed"
