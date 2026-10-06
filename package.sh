#!/usr/bin/env bash
#
# Build build/SwitchBotLockUltra.c4z from src/.
#
# Control4's packager emits an archive with NO directory entries, and driver.xml
# must have NO XML declaration. Get either wrong and Composer's "Update Driver"
# fails silently. This script refuses to build a package that breaks either.
#
# Usage:   ./package.sh
# Needs:   bash, zip, unzip, grep, sed        (luac / xmllint are used if present)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SRC=src
OUT_DIR=build
OUT="$OUT_DIR/SwitchBotLockUltra.c4z"     # keep this name stable: renaming it makes
                                          # Composer treat the driver as new

fail() { echo "package.sh: FAIL: $*" >&2; exit 1; }

command -v zip   >/dev/null || fail "zip is not installed"
command -v unzip >/dev/null || fail "unzip is not installed"

for f in driver.xml driver.lua; do
	[ -f "$SRC/$f" ] || fail "missing $SRC/$f"
done

# ---- driver.xml: no XML declaration ---------------------------------------
if head -c 64 "$SRC/driver.xml" | grep -q '<?xml'; then
	fail "driver.xml starts with an XML declaration; remove it"
fi

# ---- driver.xml: well-formed (when a checker is available) ------------------
if command -v xmllint >/dev/null; then
	xmllint --noout "$SRC/driver.xml" || fail "driver.xml is not well-formed"
elif command -v python3 >/dev/null; then
	python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$SRC/driver.xml" \
		|| fail "driver.xml is not well-formed"
fi

# ---- Lua syntax (when a checker is available) -------------------------------
LUAC=""
for c in luac5.1 luac5.4 luac; do command -v "$c" >/dev/null && { LUAC="$c"; break; }; done
if [ -n "$LUAC" ]; then
	for f in "$SRC"/*.lua; do
		"$LUAC" -p "$f" || fail "Lua syntax error in $f"
	done
fi

# ---- every file driver.xml references must exist ----------------------------
while IFS= read -r ref; do
	[ -f "$SRC/$ref" ] || fail "driver.xml references missing file: $ref"
done < <(grep -o 'file="[^"]*"' "$SRC/driver.xml" | sed 's/^file="//; s/"$//')

# sbjson is required at load time by driver.lua
if grep -q "require *('sbjson')" "$SRC/driver.lua"; then
	[ -f "$SRC/sbjson.lua" ] || fail "driver.lua requires sbjson but $SRC/sbjson.lua is missing"
fi

# ---- version consistency ----------------------------------------------------
LUA_VER=$(sed -n "s/^[[:space:]]*DRIVER_VERSION[[:space:]]*=[[:space:]]*'\([0-9.]*\)'.*/\1/p" "$SRC/driver.lua" | head -n1)
XML_PROP=$(sed -n '/<name>Driver Version<\/name>/,/<\/property>/p' "$SRC/driver.xml" \
	| sed -n 's/.*<default>\([0-9.]*\)<\/default>.*/\1/p' | head -n1)
XML_NUM=$(sed -n 's/.*<version>\([0-9]*\)<\/version>.*/\1/p' "$SRC/driver.xml" | head -n1)

[ -n "$LUA_VER" ]  || fail "could not read DRIVER_VERSION from driver.lua"
[ -n "$XML_PROP" ] || fail "could not read the Driver Version default from driver.xml"
[ -n "$XML_NUM" ]  || fail "could not read <version> from driver.xml"
[ "$LUA_VER" = "$XML_PROP" ] \
	|| fail "DRIVER_VERSION ($LUA_VER) != Driver Version default ($XML_PROP)"

# ---- build ------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$OUT"

# driver.xml first, then everything else, sorted. -D: no directory entries.
# -X: no extra file attributes. Paths are relative to src/ so the archive root
# holds driver.xml directly.
FILES=$(cd "$SRC" && find . -type f ! -name '.*' ! -path '*/.*' | sed 's|^\./||' \
	| grep -v '^driver\.xml$' | LC_ALL=C sort)

(
	cd "$SRC"
	# shellcheck disable=SC2086
	zip -q -X -D -9 "../$OUT" driver.xml $FILES
)

# ---- verify what was actually built -----------------------------------------
NAMES=$(unzip -Z1 "$OUT")

if echo "$NAMES" | grep -q '/$'; then
	fail "archive contains directory entries"
fi
[ "$(echo "$NAMES" | head -n1)" = "driver.xml" ] || fail "driver.xml is not the first entry"
unzip -p "$OUT" driver.xml | head -c 64 | grep -q '<?xml' && fail "packaged driver.xml has an XML declaration"

while IFS= read -r ref; do
	echo "$NAMES" | grep -qx "$ref" || fail "packaged archive is missing $ref"
done < <(grep -o 'file="[^"]*"' "$SRC/driver.xml" | sed 's/^file="//; s/"$//')

unzip -tq "$OUT" >/dev/null || fail "archive failed its integrity test"

echo "Built $OUT   (driver $LUA_VER, <version> $XML_NUM)"
echo "$NAMES" | sed 's/^/  /'
ls -l "$OUT" | awk '{print "  " $5 " bytes"}'
