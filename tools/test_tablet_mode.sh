#!/bin/sh
# Host tests for the Latitude 7320 tablet mode pieces: usb/tablet_mode.sh (switch parsing, rotation re-apply, on-screen
# keyboard), the intel_hid option and input report in usb/hwdetect.sh, and the service wiring in usb/hook.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- usb/tablet_mode.sh ---------------------------------------------------------------------------------------------
cat > "$T/devices" <<'EOF'
I: Bus=0019 Vendor=0000 Product=0005 Version=0000
N: Name="Lid Switch"
P: Phys=PNP0C0D/button/input0
H: Handlers=event0
B: PROP=0
B: EV=21
B: SW=1

I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
N: Name="AT Translated Set 2 keyboard"
H: Handlers=sysrq kbd leds event3
B: EV=120013
B: KEY=402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe

I: Bus=0019 Vendor=0000 Product=0000 Version=0000
N: Name="Intel HID switches"
H: Handlers=event21
B: PROP=0
B: EV=21
B: SW=2
EOF

GBOS_TABLET_MODE_LIB=1
GBOS_INPUT_DEVICES=$T/devices
GBOS_TABLET_STATE_DIR=$T/state
GBOS_TABLET_RUN_DIR=$T/run
GBOS_SYSFS_ROOT=$T/sys
mkdir -p "$T/state" "$T/run" "$T/sys/bus/serio/devices/serio0" "$T/sys/bus/serio/drivers/atkbd"
. "$ROOT/usb/tablet_mode.sh"
TM_OUT=$T/tablet-mode.txt TM_ROTATION=1 TM_KEYBOARD=ime

tm_switch_devices > "$T/switches"
cat > "$T/expected" <<'EOF'
/dev/input/event0 lid "Lid Switch"
/dev/input/event21 tablet "Intel HID switches"
EOF
diff -u "$T/expected" "$T/switches"
[ "$(tm_tablet_device)" = /dev/input/event21 ] || fail "tablet device not found"

# getevent -qS stub. Android's toolbox prints only the bits for one device ("0002", seen on every Latitude
# boot); GETEVENT_PREFIX=1 also checks a "<device>: <bits>" form.
GETEVENT_BITS=0002
GETEVENT_PREFIX=0
GETEVENT_TYPED=
getevent() {
  # -qc 1 NODE: a key typed on NODE (listed in GETEVENT_TYPED) or the device went away (error).
  if [ "$1 $2" = "-qc 1" ]; then case " $GETEVENT_TYPED " in *" $3 "*) echo "0001 001e 00000001"; return 0 ;; *) return 1 ;; esac; fi
  [ "$1" = -qS ] || return 1
  [ -n "$GETEVENT_BITS" ] || return 0
  if [ "$GETEVENT_PREFIX" = 1 ]; then printf '%s: %s\n' "$2" "$GETEVENT_BITS"; else printf '%s\n' "$GETEVENT_BITS"; fi
  return 0
}
[ "$(tm_tablet_state /dev/input/event21)" = 1 ] || fail "SW_TABLET_MODE=1 not parsed"
GETEVENT_BITS=0003
[ "$(tm_tablet_state /dev/input/event21)" = 1 ] || fail "lid+tablet bits not parsed"
GETEVENT_BITS=0001
[ "$(tm_tablet_state /dev/input/event21)" = 0 ] || fail "lid-only bits read as tablet"
GETEVENT_PREFIX=1 GETEVENT_BITS=0002
[ "$(tm_tablet_state /dev/input/event21)" = 1 ] || fail "prefixed SW_TABLET_MODE=1 not parsed"
GETEVENT_BITS=0000
[ "$(tm_tablet_state /dev/input/event21)" = 0 ] || fail "prefixed cover-attached bits not parsed"
GETEVENT_PREFIX=0
GETEVENT_BITS=
[ "$(tm_tablet_state /dev/input/event21)" = unknown ] || fail "empty getevent output not unknown"
[ "$(tm_tablet_state '')" = unknown ] || fail "missing device not unknown"
GBOS_INPUT_DEVICES=$T/none TM_INPUT_DEVICES=$T/none
[ -z "$(tm_tablet_device)" ] || fail "device found without /proc/bus/input/devices"
TM_INPUT_DEVICES=$T/devices GBOS_INPUT_DEVICES=$T/devices

# Rotation: re-applied only when LaptopController has reset it, and logged.
echo default > "$T/rotation"
cmd() {
  [ "$1 $2" = "window fixed-to-user-rotation" ] || { [ "$1 $2" = "window user-rotation" ] && echo lock 0; return 0; }
  if [ $# -eq 3 ]; then echo "$3" > "$T/rotation"; echo "set $3" >> "$T/cmd.log"; else cat "$T/rotation"; fi
}
dumpsys() { echo "  mCommittedState=DeviceState{identifier=3, name='TABLET'}"; }
timeout() { shift; "$@"; }
: > "$T/tablet-mode.txt"
tm_rotation_check boot
[ "$(cat "$T/rotation")" = disabled ] || fail "rotation policy not re-applied"
grep -q "rotation: fixed-to-user-rotation was 'default' (boot); re-applied disabled, now 'disabled'" "$T/tablet-mode.txt" ||
  fail "re-apply not logged: $(cat "$T/tablet-mode.txt")"
: > "$T/cmd.log"; : > "$T/tablet-mode.txt"
tm_rotation_check poll
[ ! -s "$T/cmd.log" ] && [ ! -s "$T/tablet-mode.txt" ] || fail "rotation re-applied although already disabled"
TM_ROTATION=0
echo default > "$T/rotation"
tm_rotation_check poll
[ "$(cat "$T/rotation")" = default ] || fail "rotation changed with ROTATION=0"
TM_ROTATION=1

# Keyboard (ime): saved on detach, restored on attach; only on a mode change; every user (user 10 = the desktop user,
# started after the helper's first run on hardware).
USERS='0'
pm() { [ "$1 $2" = "list users" ] || return 1; echo Users:; for _x in $USERS; do printf '\tUserInfo{%s:User%s:c13} running\n' "$_x" "$_x"; done; }
settings() {
  [ "$1" = --user ] || { echo "settings without --user: $*" >> "$T/errors"; return 1; }
  case "$2" in ''|*[!0-9]*) [ "$2" = current ] || { echo "bad user: $*" >> "$T/errors"; return 1; } ;; esac
  _su=$2; shift 2
  case "$1" in
    get) cat "$T/ime.$_su" 2>/dev/null || echo null ;;
    put) echo "$4" > "$T/ime.$_su" ;;
    delete) rm -f "$T/ime.$_su"; echo "Deleted 1 rows" ;;
  esac
}
# Device state: cmd device_state state N|reset; dumpsys shows the committed state (3 = TABLET, the switch's base state).
echo 3 > "$T/ds"
cmd() {
  case "$1 $2" in
    "device_state state")
      echo "$3" >> "$T/ds.log"
      if [ "$3" = reset ]; then echo 3 > "$T/ds"; else echo "$3" > "$T/ds"; fi ;;
    "window fixed-to-user-rotation") echo disabled ;;
    "window user-rotation") echo lock 0 ;;
  esac
  return 0
}
dumpsys() { echo "  mCommittedState=Optional[DeviceState{identifier=$(cat "$T/ds"), name='X'}]"; }
TM_EXT_KEYBOARD=desktop
echo 0 > "$T/ime.0"
TM_DEV=/dev/input/event21
GETEVENT_BITS=0002
tm_apply_mode test || fail "detach not applied"
[ "$(cat "$T/ime.0")" = 1 ] && [ "$(cat "$T/state/ime_saved.0")" = 0 ] || fail "tablet did not enable show_ime_with_hard_keyboard"
grep -q 'mode tablet (was unset, test); SW_TABLET_MODE=1; external keyboards: none' "$T/tablet-mode.txt" || fail "mode change not logged: $(cat "$T/tablet-mode.txt")"
if tm_apply_mode again; then fail "unchanged state applied twice"; fi
# The desktop user starts later: the slow poll gives it the setting too, and leaves user 0 alone.
USERS='0 10'; echo 0 > "$T/ime.10"; : > "$T/tablet-mode.txt"
tm_keep_mode
[ "$(cat "$T/ime.10")" = 1 ] && [ "$(cat "$T/state/ime_saved.10")" = 0 ] || fail "user 10 did not get show_ime_with_hard_keyboard"
grep -q 'user 10 show_ime_with_hard_keyboard=1' "$T/tablet-mode.txt" && ! grep -q 'user 0 ' "$T/tablet-mode.txt" || fail "keep_mode log wrong: $(cat "$T/tablet-mode.txt")"
: > "$T/tablet-mode.txt"; tm_keep_mode
[ ! -s "$T/tablet-mode.txt" ] || fail "keep_mode logged without a change"
[ ! -e "$T/ds.log" ] || fail "device state touched in tablet mode"
GETEVENT_BITS=0000
tm_apply_mode attach || fail "attach not applied"
[ "$(cat "$T/ime.0")" = 0 ] && [ "$(cat "$T/ime.10")" = 0 ] && [ -z "$(ls "$T/state" | grep ime_saved)" ] ||
  fail "laptop did not restore show_ime_with_hard_keyboard for both users"
[ ! -e "$T/ds.log" ] || fail "device state reset without a request of ours"
# The setting was never set (null): restore by deleting it.
USERS=0; rm -f "$T/ime.0" "$T/ime.10" "$T/run/mode"
GETEVENT_BITS=0002; tm_apply_mode detach
[ "$(cat "$T/state/ime_saved.0")" = null ] || fail "null setting not saved"
GETEVENT_BITS=0000; tm_apply_mode attach
[ ! -e "$T/ime.0" ] || fail "null setting not deleted on attach"
# A reboot in tablet mode: the next start in laptop state restores the saved value (also the old single-file record).
echo 1 > "$T/ime.0"; echo 0 > "$T/state/ime_saved"; rm -f "$T/run/mode"
tm_apply_mode start
[ "$(cat "$T/ime.0")" = 0 ] && [ ! -e "$T/state/ime_saved" ] || fail "stale tablet setting not restored at start"

# External keyboard -> desktop mode. USB keyboard and a Bluetooth one count; a USB mouse, a consumer-control device
# (kbd handler, no letters) and the pen do not; the EC's i8042 keyboard does not.
cp "$T/devices" "$T/devices-ext"
cat >> "$T/devices-ext" <<'EOF'

I: Bus=0003 Vendor=046d Product=c077 Version=0111
N: Name="USB Optical Mouse"
H: Handlers=mouse0 event22
B: EV=17
B: KEY=70000 0 0 0 0

I: Bus=0003 Vendor=03f0 Product=0024 Version=0110
N: Name="HP USB Keyboard Consumer Control"
H: Handlers=kbd event24
B: EV=1f
B: KEY=3f000303ff 0 0 483ffff17aff32d bfd4444600000000 1 130ff38b17c007 ffe77bfad9415fff febeffdfffefffff fffffffffffffffe

I: Bus=0018 Vendor=2d1f Product=49a5 Version=0100
N: Name="Wacom HID 49A5 Pen"
H: Handlers=kbd event25
B: KEY=1c03 0 0 0 0 0
EOF
TM_INPUT_DEVICES=$T/devices-ext
[ "$(tm_ext_keyboards)" = 'event24||"HP USB Keyboard Consumer Control"' ] || fail "consumer control with letters: $(tm_ext_keyboards)"
# A real consumer-control device has no letter keys.
sed -i 's/^B: KEY=3f000303ff 0 0 483ffff17aff32d.*/B: KEY=1 0 0 0 0 0 0 0 7c000000000/' "$T/devices-ext"
cat >> "$T/devices-ext" <<'EOF2'

I: Bus=0003 Vendor=1234 Product=0001 Version=0100
N: Name="Half Keypad"
H: Handlers=kbd event27
B: KEY=43ff0000
EOF2
[ -z "$(tm_ext_keyboards)" ] || fail "consumer control / mouse / pen counted as a keyboard: $(tm_ext_keyboards)"
cat >> "$T/devices-ext" <<'EOF'

I: Bus=0003 Vendor=03f0 Product=0024 Version=0110
N: Name="HP USB Keyboard"
H: Handlers=sysrq kbd leds event23
B: EV=120013
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe

I: Bus=0005 Vendor=05ac Product=0255 Version=0050
N: Name="BT Keyboard"
H: Handlers=sysrq kbd leds event26
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe
EOF
[ "$(tm_ext_keyboards | tr '\n' ,)" = 'event23||"HP USB Keyboard",event26||"BT Keyboard",' ] || fail "external keyboards not found: $(tm_ext_keyboards)"

USERS='0 10'; echo 0 > "$T/ime.0"; echo 0 > "$T/ime.10"; rm -f "$T/run/mode" "$T/ds.log"; echo 3 > "$T/ds"; : > "$T/tablet-mode.txt"
TM_INPUT_DEVICES=$T/devices
GETEVENT_BITS=0002; tm_apply_mode detach
[ "$(cat "$T/run/mode")" = tablet ] && [ "$(cat "$T/ime.10")" = 1 ] || fail "no tablet mode before the keyboard"
TM_INPUT_DEVICES=$T/devices-ext
# Plugged in but nothing typed (a mouse receiver's keyboard interface looks the same): still tablet.
GETEVENT_TYPED=; tm_kbd_watch; wait
if tm_apply_mode "keyboard in"; then fail "desktop without a key typed"; fi
[ "$(cat "$T/run/mode")" = tablet ] && [ ! -e "$T/ds.log" ] || fail "an untyped keyboard changed the mode"
[ -z "$(ls "$T/run" | grep -E '^(watch|typed)\.')" ] || fail "watch/typed records left without a key: $(ls "$T/run")"
# A key typed on the HP keyboard: desktop (the BT keyboard, never typed on, is not listed).
GETEVENT_TYPED=/dev/input/event23; tm_kbd_watch; wait
[ "$(cat "$T/run/typed.event23")" = 'event23||"HP USB Keyboard"' ] && [ ! -e "$T/run/typed.event26" ] || fail "typed record wrong: $(ls "$T/run")"
grep -q 'keyboard: typed on event23 "HP USB Keyboard"' "$T/tablet-mode.txt" || fail "typing not logged"
tm_apply_mode "keyboard in" || fail "keyboard plug-in not applied"
[ "$(cat "$T/run/mode")" = desktop ] || fail "not desktop with an external keyboard"
# Watching again does not start a second getevent for a typed keyboard.
GETEVENT_TYPED=; tm_kbd_watch; wait
[ -e "$T/run/typed.event23" ] || fail "typed record dropped by a later watch"
[ "$(cat "$T/ds.log")" = 2 ] && [ -e "$T/run/override" ] || fail "desktop state not requested: $(cat "$T/ds.log" 2>/dev/null)"
[ "$(cat "$T/ime.0")" = 0 ] && [ "$(cat "$T/ime.10")" = 0 ] || fail "on-screen keyboard setting not restored in desktop mode"
grep -q 'mode desktop (was tablet, keyboard in); SW_TABLET_MODE=1; external keyboards: "HP USB Keyboard"; ' "$T/tablet-mode.txt" ||
  fail "desktop not logged: $(cat "$T/tablet-mode.txt")"
grep -q 'desktop: requested device state 2' "$T/tablet-mode.txt" || fail "request not logged"
# Android dropped the request: the slow poll asks again; while it holds, nothing happens.
echo 3 > "$T/ds"; tm_keep_mode
[ "$(tr '\n' ' ' < "$T/ds.log")" = '2 2 ' ] || fail "lost request not renewed: $(cat "$T/ds.log")"
tm_keep_mode
[ "$(tr '\n' ' ' < "$T/ds.log")" = '2 2 ' ] || fail "request renewed while it held"
# Unplugged: back to tablet, request reset, on-screen keyboard again.
TM_INPUT_DEVICES=$T/devices
tm_apply_mode "keyboard out" || fail "unplug not applied"
[ "$(cat "$T/run/mode")" = tablet ] && [ "$(tail -n 1 "$T/ds.log")" = reset ] && [ ! -e "$T/run/override" ] || fail "unplug did not reset the device state"
[ "$(cat "$T/ime.10")" = 1 ] || fail "on-screen keyboard not back after unplug"
# Another device on the same node number is not "typed".
sed 's/^N: Name="HP USB Keyboard"$/N: Name="Other Keyboard"/' "$T/devices-ext" > "$T/devices-other"
TM_INPUT_DEVICES=$T/devices-other
[ -z "$(tm_typed_keyboards)" ] || fail "typed record matched another device: $(tm_typed_keyboards)"
# Cover attached with the keyboard in: laptop, request reset.
TM_INPUT_DEVICES=$T/devices-ext; tm_apply_mode "keyboard in"; GETEVENT_BITS=0000; tm_apply_mode attach
[ "$(cat "$T/run/mode")" = laptop ] && [ "$(tail -n 1 "$T/ds.log")" = reset ] && [ "$(cat "$T/ime.10")" = 0 ] || fail "attach from desktop wrong"
# EXT_KEYBOARD=0: the keyboard changes nothing.
TM_EXT_KEYBOARD=0; rm -f "$T/run/mode"; GETEVENT_BITS=0002; tm_apply_mode detach
[ "$(cat "$T/run/mode")" = tablet ] || fail "EXT_KEYBOARD=0 still went to desktop"
GETEVENT_BITS=0000; tm_apply_mode attach; TM_EXT_KEYBOARD=desktop
TM_INPUT_DEVICES=$T/devices
[ ! -e "$T/errors" ] || fail "$(cat "$T/errors")"

# Keyboard (unbind): atkbd detached with "none" (no newline: serio uses strncmp with the write length), rebound on attach.
TM_KEYBOARD=unbind
ln -s ../../drivers/atkbd "$T/sys/bus/serio/devices/serio0/driver"
echo 'i8042 KBD port' > "$T/sys/bus/serio/devices/serio0/description"
: > "$T/sys/bus/serio/devices/serio0/drvctl"; : > "$T/sys/bus/serio/devices/serio0/bind_mode"
rm -f "$T/run/mode"
GETEVENT_BITS=0002; tm_apply_mode detach
[ "$(cat "$T/sys/bus/serio/devices/serio0/drvctl")" = none ] || fail "atkbd not detached"
[ "$(wc -c < "$T/sys/bus/serio/devices/serio0/drvctl")" -eq 4 ] || fail "drvctl write has a trailing newline"
[ "$(cat "$T/sys/bus/serio/devices/serio0/bind_mode")" = manual ] || fail "bind_mode not manual"
[ "$(cat "$T/state/atkbd_ports")" = serio0 ] || fail "detached port not recorded"
rm "$T/sys/bus/serio/devices/serio0/driver"
GETEVENT_BITS=0000; tm_apply_mode attach
[ "$(cat "$T/sys/bus/serio/devices/serio0/drvctl")" = atkbd ] || fail "atkbd not rebound"
[ "$(cat "$T/sys/bus/serio/devices/serio0/bind_mode")" = auto ] || fail "bind_mode not restored"
[ ! -e "$T/state/atkbd_ports" ] || fail "port record not cleared"
TM_KEYBOARD=ime
unset -f getevent cmd dumpsys settings timeout pm

# ---- usb/hwdetect.sh ------------------------------------------------------------------------------------------------
log() { printf '%s\n' "$*" >> "$T/hwlog"; }
. "$ROOT/usb/hwdetect.sh"
mkdir -p "$T/sys/class/dmi/id"
printf 'Dell Inc.\n' > "$T/sys/class/dmi/id/sys_vendor"
printf 'Latitude 7320 Detachable\n' > "$T/sys/class/dmi/id/product_name"
printf '32\n' > "$T/sys/class/dmi/id/chassis_type"
MODOPTS=
[ "$(gbos_tablet_switch_opts 2>/dev/null)" = 'options intel_hid enable_sw_tablet_mode=2' ] || fail "intel_hid option not written"
TABLET_SWITCH=1
[ "$(gbos_tablet_switch_opts 2>/dev/null)" = 'options intel_hid enable_sw_tablet_mode=1' ] || fail "TABLET_SWITCH=1 ignored"
TABLET_SWITCH=0
[ -z "$(gbos_tablet_switch_opts 2>/dev/null)" ] || fail "TABLET_SWITCH=0 still wrote an option"
TABLET_SWITCH=bogus
[ "$(gbos_tablet_switch_opts 2>/dev/null)" = 'options intel_hid enable_sw_tablet_mode=2' ] || fail "unknown TABLET_SWITCH not defaulted"
unset TABLET_SWITCH
MODOPTS="xe.enable_psr=0 intel_hid.enable_sw_tablet_mode=1"
[ -z "$(gbos_tablet_switch_opts 2>/dev/null)" ] || fail "MODOPTS override not respected"
MODOPTS=
printf 'Latitude 7320\n' > "$T/sys/class/dmi/id/product_name"
[ -z "$(gbos_tablet_switch_opts 2>/dev/null)" ] || fail "option written on another laptop"
printf 'Latitude 7320 Detachable\n' > "$T/sys/class/dmi/id/product_name"
# gbos_modopts writes it before its MODOPTS early return.
sed -n '/^gbos_modopts() {/,/^}/p' "$ROOT/usb/hwdetect.sh" > "$T/modopts.sh"
awk '/gbos_tablet_switch_opts >>/ { t = NR } /\[ -n "\$MODOPTS" \] \|\|/ { m = NR } END { exit !(t && m && t < m) }' "$T/modopts.sh" ||
  fail "gbos_modopts does not write the tablet switch option before MODOPTS"

mkdir -p "$T/sys/class/input/input21/capabilities" "$T/sys/module/intel_hid/parameters" "$T/sys/bus/acpi/devices/INTC1051:00"
echo 'Intel HID switches' > "$T/sys/class/input/input21/name"
echo 21 > "$T/sys/class/input/input21/capabilities/ev"
echo 2 > "$T/sys/class/input/input21/capabilities/sw"
echo 2 > "$T/sys/module/intel_hid/parameters/enable_sw_tablet_mode"
GBOS_PROC_MODULES=$T/modules; : > "$T/modules"
dmesg() { echo '[   15.3] intel-hid INTC1051:00: platform supports switches'; }
gbos_report_input > "$T/input-report" 2>&1
grep -q 'chassis_type=32 intel_hid enable_sw_tablet_mode=2 intel_vbtn=not loaded' "$T/input-report" || fail "tablet switch summary missing"
grep -q '^input21 Intel HID switches: ev=21 sw=2$' "$T/input-report" || fail "input capabilities missing"
grep -q '^serio0 i8042 KBD port driver= bind_mode=auto$' "$T/input-report" || fail "serio report missing"
grep -q 'ACPI: INTC1051:00' "$T/input-report" || fail "ACPI ids missing"
grep -q 'platform supports switches' "$T/input-report" || fail "intel_hid dmesg missing"
grep -q 'N: Name="Intel HID switches"' "$T/input-report" || fail "/proc/bus/input/devices missing"
grep -q '^    gbos_report_input$' "$ROOT/usb/hwdetect.sh" || fail "gbos_hw_report does not call gbos_report_input"
unset -f dmesg

# ---- usb/hook.sh service wiring -------------------------------------------------------------------------------------
sed -n '/^gbos_tablet_mode_config() {/,/^}/p' "$ROOT/usb/hook.sh" > "$T/hook-tablet.sh"
[ -s "$T/hook-tablet.sh" ] || fail "gbos_tablet_mode_config missing"
. "$T/hook-tablet.sh"
SYSFS=$T/sys G=$T/gbos N=7
mkdir -p "$G"; : > "$G/tablet_mode.sh"
GBOS_SENSOR_ROTATION_POLICY_SELECTED=1
gbos_tablet_mode_config
[ "$GBOS_TABLET_MODE_START" = '    start gbos_tablet_mode' ] || fail "helper not started"
case "$GBOS_TABLET_MODE_SERVICE" in
  'service gbos_tablet_mode /system/bin/sh /postinstall/gbos/tablet_mode.sh /postinstall/gbos/logs/boot-7/tablet-mode.txt 1 ime desktop'*'seclabel u:r:shell:s0'*oneshot*disabled) ;;
  *) fail "unexpected service: $GBOS_TABLET_MODE_SERVICE" ;;
esac
[ -z "$GBOS_ROTATION_OVERRIDE_PROP" ] || fail "override prop set by default"
ROTATION_OVERRIDE=1 TABLET_KEYBOARD=unbind
gbos_tablet_mode_config
[ "$GBOS_ROTATION_OVERRIDE_PROP" = '    setprop config.override_forced_orient true' ] || fail "ROTATION_OVERRIDE=1 ignored"
case "$GBOS_TABLET_MODE_SERVICE" in *'tablet-mode.txt 1 unbind desktop'*) ;; *) fail "TABLET_KEYBOARD=unbind ignored" ;; esac
TABLET_EXT_KEYBOARD=0; gbos_tablet_mode_config
case "$GBOS_TABLET_MODE_SERVICE" in *'tablet-mode.txt 1 unbind 0'*) ;; *) fail "TABLET_EXT_KEYBOARD=0 ignored" ;; esac
TABLET_EXT_KEYBOARD=bogus; gbos_tablet_mode_config
case "$GBOS_TABLET_MODE_SERVICE" in *'tablet-mode.txt 1 unbind desktop'*) ;; *) fail "unknown TABLET_EXT_KEYBOARD not defaulted" ;; esac
unset TABLET_EXT_KEYBOARD
GBOS_SENSOR_ROTATION_POLICY_SELECTED=0
gbos_tablet_mode_config
case "$GBOS_TABLET_MODE_SERVICE" in *'tablet-mode.txt 0 unbind desktop'*) ;; *) fail "rotation enforced without the rotation trial" ;; esac
[ -z "$GBOS_ROTATION_OVERRIDE_PROP" ] || fail "override prop set without the rotation trial"
unset ROTATION_OVERRIDE TABLET_KEYBOARD
TABLET_MODE=0
gbos_tablet_mode_config
[ -z "$GBOS_TABLET_MODE_START$GBOS_TABLET_MODE_SERVICE" ] || fail "TABLET_MODE=0 still starts the helper"
unset TABLET_MODE
printf 'Latitude 7320\n' > "$T/sys/class/dmi/id/product_name"
gbos_tablet_mode_config
[ -z "$GBOS_TABLET_MODE_START$GBOS_TABLET_MODE_SERVICE" ] || fail "helper started on another laptop"

grep -q '^\$GBOS_TABLET_MODE_SERVICE$' "$ROOT/usb/hook.sh" || fail "service not in gbos.rc"
grep -q '^\$GBOS_TABLET_MODE_START$' "$ROOT/usb/hook.sh" || fail "start not in gbos.rc"
grep -q '^\$GBOS_ROTATION_OVERRIDE_PROP$' "$ROOT/usb/hook.sh" || fail "override prop not in gbos.rc"
grep -q '^  gbos_tablet_mode_config$' "$ROOT/usb/hook.sh" || fail "gbos_tablet_mode_config not called"
for f in usb/install.sh tools/deploy_stick.sh tools/make_gbos86_image.sh; do
  grep -q 'tablet_mode\.sh' "$ROOT/$f" || fail "$f does not ship tablet_mode.sh"
done
sh -n "$ROOT/usb/tablet_mode.sh"

echo "tablet mode tests passed"
