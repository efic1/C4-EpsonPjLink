#!/bin/sh
# Build epson_pjlink.c4z. Runs the tests first and refuses to package a failing driver.
set -e
cd "$(dirname "$0")"

LUA=$(command -v lua5.1 || command -v luajit || command -v lua)
[ -n "$LUA" ] || { echo "No Lua interpreter found (install lua5.1 or luajit)"; exit 1; }

echo "== XML check";   python3 tools/check_xml.py driver.xml
echo "== Tests";       "$LUA" tests/run.lua | tail -3
echo "== Docs (RTF)";  python3 tools/md_to_rtf.py www/documentation.md www/documentation.rtf

rm -f epson_pjlink.c4z
# A .c4z is a plain zip: driver.xml at the root, no tests or tooling inside.
zip -q -r -X -D epson_pjlink.c4z driver.xml driver.lua lib www
echo "== Built epson_pjlink.c4z"
unzip -l epson_pjlink.c4z
