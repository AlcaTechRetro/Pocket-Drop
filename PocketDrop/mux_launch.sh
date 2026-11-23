#!/bin/sh
# HELP: Browse your own download sources and save files straight into your ROMS folders.
# ICON: pocketdrop
# GRID: Pocket Drop

# muOS mounts the app here whichever SD card it is on.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
APP_DIR="/run/muos/storage/application/PocketDrop"
[ -d "$APP_DIR" ] || APP_DIR="$SELF_DIR"

# --- Diagnostics first: written before anything that could stop the script ---
LOG="$APP_DIR/launch.txt"
{
	echo "Pocket Drop launcher 1.0 - $(date)"
	echo "script: $0"
	uname -a
	for V in /opt/muos/config/version.txt /opt/muos/config/system/version /opt/muos/config/system/build; do
		[ -f "$V" ] && echo "muOS $V: $(head -2 "$V" | tr '\n' ' ')"
	done
	echo "func.sh present: $([ -f /opt/muos/script/var/func.sh ] && echo yes || echo NO)"
} > "$LOG" 2>&1

# muOS shared setup - never remove this line.
if [ -f /opt/muos/script/var/func.sh ]; then
	. /opt/muos/script/var/func.sh
fi

APP_BIN="love"
if command -v SETUP_APP >/dev/null 2>&1; then
	SETUP_APP "$APP_BIN" "" >> "$LOG" 2>&1
	echo "SETUP_APP done" >> "$LOG"
else
	echo "SETUP_APP not available on this muOS version" >> "$LOG"
fi

cd "$APP_DIR" || { echo "cannot cd to $APP_DIR" >> "$LOG"; exit 1; }
echo "app folder: $APP_DIR" >> "$LOG"

# --- The LOVE engine comes inside the app (bin/love + bin/libs) ----------------
LOVE=""
RUNNER=""
if [ -f "$APP_DIR/bin/love" ]; then
	# Check the engine files aren't damaged (e.g. after the console lost power
	# while writing to the SD card).
	if [ -f "$APP_DIR/bin/checksums.md5" ] && command -v md5sum >/dev/null 2>&1; then
		if (cd "$APP_DIR/bin" && md5sum -c checksums.md5 >> "$LOG" 2>&1); then
			echo "engine files OK" >> "$LOG"
		else
			MSG="The LOVE engine files in PocketDrop/bin are damaged. Copy the bin folder again from the Pocket Drop zip (and check the SD card for errors on your PC)."
			echo "$MSG" >> "$LOG"
			echo "$MSG" > "$APP_DIR/log.txt"
			exit 1
		fi
	fi
	export LD_LIBRARY_PATH="$APP_DIR/bin/libs:$LD_LIBRARY_PATH"
	chmod +x "$APP_DIR/bin/love" 2>/dev/null
	LOVE="$APP_DIR/bin/love"
	if [ ! -x "$LOVE" ]; then
		for LD in /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1 /usr/lib/ld-linux-aarch64.so.1; do
			[ -z "$RUNNER" ] && [ -x "$LD" ] && RUNNER="$LD"
		done
		echo "bin/love is not marked runnable; using loader: $RUNNER" >> "$LOG"
	fi
else
	LOVE="$(command -v love 2>/dev/null)"
	for P in /usr/bin/love /opt/muos/bin/love /opt/muos/extra/love; do
		[ -z "$LOVE" ] && [ -x "$P" ] && LOVE="$P"
	done
fi

if [ -z "$LOVE" ]; then
	echo "LOVE was not found: the bin folder is missing from PocketDrop." | tee -a "$LOG" > "$APP_DIR/log.txt"
	exit 1
fi

# A Pocket Drop that didn't close properly keeps the screen busy, so a new one
# can't open its window: close leftover LOVE processes first.
OLD=""
for P in $(pidof love 2>/dev/null); do [ "$P" != "$$" ] && OLD="$OLD $P" && kill "$P" 2>/dev/null; done
if [ -n "$OLD" ]; then
	echo "closed leftover LOVE process(es):$OLD" >> "$LOG"
	sleep 1
	for P in $OLD; do kill -9 "$P" 2>/dev/null; done
fi
rm -f "$APP_DIR/tmp/download.pid" "$APP_DIR/tmp/download.cancel" 2>/dev/null

# Check the engine's libraries (lists any that are "not found").
echo "--- libraries ---" >> "$LOG"
LD_TRACE_LOADED_OBJECTS=1 $RUNNER "$LOVE" 2>&1 | grep -E "not found|SDL2|openal|freetype" >> "$LOG"
echo "--- environment ---" >> "$LOG"
env | grep -E "^(SDL|LD_|HOME|DISPLAY|WAYLAND|LOVE)" >> "$LOG"

run_love() {
	echo "--- start ($1) at $(date +%s) ---" >> "$LOG"
	START=$(date +%s)
	if [ -n "$RUNNER" ]; then
		"$RUNNER" "$LOVE" "$APP_DIR" >> "$LOG" 2>&1
	else
		"$LOVE" "$APP_DIR" >> "$LOG" 2>&1
	fi
	CODE=$?
	TOOK=$(( $(date +%s) - START ))
	echo "--- LOVE exited with code $CODE after ${TOOK}s ---" >> "$LOG"
}

run_love "normal"
# If it failed straight away (window/graphics problem), retry in OpenGL ES mode.
if [ "$CODE" != "0" ] && [ "$TOOK" -lt 5 ]; then
	export LOVE_GRAPHICS_USE_OPENGLES=1
	run_love "OpenGL ES"
fi
