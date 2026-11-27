#!/bin/sh
# Host test for usb/hook.sh gbos_ignore_input_devices: IGNORE_INPUT_DEVICES in gbos.cfg adds names to Google's
# /vendor/etc/excluded-input-devices.xml (a copy bind-mounted over it), so Android never opens those input devices.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

sed -n '/^gbos_ignore_input_devices() {/,/^}/p' "$ROOT/usb/hook.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || fail "gbos_ignore_input_devices missing from hook.sh"
grep -q '^gbos_ignore_input_devices$' "$ROOT/usb/hook.sh" || fail "gbos_ignore_input_devices not called in hook.sh"
. "$T/fn.sh"

log() { printf '%s\n' "$*" >> "$T/log"; }
# mount --bind SRC DST: record it and copy SRC over DST so the test can read the result where Android would.
mount() {
  [ "$1" = --bind ] || { echo "unexpected mount $*" >> "$T/errors"; return 1; }
  echo "$2 -> $3" >> "$T/mounts"; cat "$2" > "$3"
}

NEWROOT=$T/new
GBOS_INPUT_IGNORE_DIR=$T/dev-input
mkdir -p "$NEWROOT/vendor/etc"
cat > "$NEWROOT/vendor/etc/excluded-input-devices.xml" <<'EOF'
<!-- Google's comment -->
<devices>
    <device name="Power Button"/>
</devices>
EOF
cp "$NEWROOT/vendor/etc/excluded-input-devices.xml" "$T/google.xml"

# Not set: nothing happens.
unset IGNORE_INPUT_DEVICES || true
gbos_ignore_input_devices
[ ! -e "$T/mounts" ] && cmp -s "$T/google.xml" "$NEWROOT/vendor/etc/excluded-input-devices.xml" || fail "changed without IGNORE_INPUT_DEVICES"

# Two names (comma-separated, spaces kept, blanks around commas trimmed), one with XML specials.
IGNORE_INPUT_DEVICES='2.4G Receiver , Foo & <Bar> "Baz"'
gbos_ignore_input_devices
[ "$(wc -l < "$T/mounts")" -eq 1 ] || fail "not bind-mounted once: $(cat "$T/mounts")"
X=$NEWROOT/vendor/etc/excluded-input-devices.xml
grep -q '<device name="Power Button"/>' "$X" || fail "Google's entry lost"
grep -q '^    <device name="2.4G Receiver"/>$' "$X" || fail "receiver not added: $(cat "$X")"
grep -qF '<device name="Foo &amp; &lt;Bar&gt; &quot;Baz&quot;"/>' "$X" || fail "XML specials not escaped: $(cat "$X")"
[ "$(grep -c '</devices>' "$X")" -eq 1 ] && tail -n 1 "$X" | grep -q '^</devices>$' || fail "closing tag wrong: $(cat "$X")"
awk '/2.4G Receiver/ { a = NR } /<\/devices>/ { b = NR } END { exit !(a && b && a < b) }' "$X" || fail "entry not inside <devices>"
grep -q 'hook: input devices ignored by Android: "2.4G Receiver", "Foo & <Bar> \\"Baz\\""' "$T/log" || fail "not logged: $(cat "$T/log")"
case "$(cat "$T/mounts")" in "$T/dev-input/excluded-input-devices.xml -> $X") ;; *) fail "bind source not under /dev: $(cat "$T/mounts")" ;; esac

# Google's file missing (another build): log and leave it alone.
rm -f "$X" "$T/mounts" "$T/log"
IGNORE_INPUT_DEVICES='2.4G Receiver'
gbos_ignore_input_devices || fail "missing file made the hook fail"
[ ! -e "$T/mounts" ] && grep -q 'NOT applied' "$T/log" || fail "missing file not reported: $(cat "$T/log" 2>/dev/null)"

[ ! -e "$T/errors" ] || fail "$(cat "$T/errors")"
grep -q '^#IGNORE_INPUT_DEVICES=' "$ROOT/usb/gbos.cfg" || fail "IGNORE_INPUT_DEVICES not documented in usb/gbos.cfg"
sh -n "$ROOT/usb/hook.sh"
echo "INPUT_IGNORE_TEST_PASS"
