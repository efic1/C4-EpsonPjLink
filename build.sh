#!/bin/sh
# Build epson_pjlink.c4z. Runs the tests first and refuses to package a failing driver.
set -e
cd "$(dirname "$0")"

LUA=$(command -v lua5.1 || command -v luajit || command -v lua)
[ -n "$LUA" ] || { echo "No Lua interpreter found (install lua5.1 or luajit)"; exit 1; }

echo "== XML check";   python3 tools/check_xml.py driver.xml
# Every network-event mode, because Control4 reports some events from inside the call that
# causes them and the original async-only tests missed a hang that this exposes. Capture the
# output instead of piping the runner straight into tail, which would hide its exit status.
for mode in async disconnect all; do
  echo "== Tests [network events: $mode]"
  out=$(C4_SYNC=$mode "$LUA" tests/run.lua 2>&1) || { echo "$out" | grep -E "FAIL|expected|passed" ; echo "TESTS FAILED ($mode)"; exit 1; }
  echo "$out" | tail -1
done
echo "== Docs (RTF)";  python3 tools/md_to_rtf.py www/documentation.md www/documentation.rtf

rm -f epson_pjlink.c4z
# A .c4z is a plain zip: driver.xml at the root, no tests or tooling inside.
zip -q -r -X -D epson_pjlink.c4z driver.xml driver.lua lib www
echo "== Built epson_pjlink.c4z"
unzip -l epson_pjlink.c4z
