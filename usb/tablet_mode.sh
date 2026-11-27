#!/system/bin/sh
# Latitude 7320 Detachable: tablet mode helper. hook.sh starts it (service gbos_tablet_mode) after boot_completed,
# only on that DMI identity.
#   tablet_mode.sh LOG ROTATION KEYBOARD EXT_KEYBOARD
#     ROTATION=1: keep "cmd window fixed-to-user-rotation disabled" applied. Google's
#       DisplayRotation$LaptopController.refreshConfig (services.jar) resets it to "default" (= fixed on a PC) on every
#       device-state callback outside tablet state: at boot (a race with a one-shot command, lost on boot-9 2026-11-18)
#       and after every lid or tablet-switch change. Each re-apply is logged.
#     KEYBOARD=ime: in tablet mode set Settings.Secure show_ime_with_hard_keyboard=1 for every user, and restore the
#       previous values when the keyboard cover is attached again. The EC's i8042 "AT Translated Set 2 keyboard" exists
#       with the cover off too, so Android always sees a hardware keyboard and hides the on-screen one.
#     KEYBOARD=unbind: detach atkbd from its serio port in tablet mode instead, rebind on attach (that device then
#       disappears; whatever else the EC reports through it, e.g. hardware buttons, goes with it).
#     KEYBOARD=0: leave the keyboard alone.
#     EXT_KEYBOARD=desktop (default): cover off and a USB or Bluetooth keyboard plugged in = desktop mode: Android's laptop
#       device state is requested and the on-screen keyboard setting restored; unplugging it goes back to tablet mode.
#       EXT_KEYBOARD=0: an external keyboard changes nothing.
# Tablet state comes from SW_TABLET_MODE (intel_hid "Intel HID switches", enable_sw_tablet_mode=2 from hwdetect.sh).
# Change detection: one "getevent -c 1" per switch device as a wake-up (getevent's stdout is block-buffered in a pipe,
# so its event lines cannot be streamed), then the authoritative state from "getevent -qS"; a slow loop reconciles
# anything missed between wake-ups. Without a switch device only the rotation part runs.
# GBOS_TABLET_MODE_LIB=1 only defines the functions (tools/test_tablet_mode.sh).

TM_OUT=${1:-/postinstall/gbos/logs/tablet-mode.txt}
TM_ROTATION=${2:-0}
TM_KEYBOARD=${3:-ime}
TM_EXT_KEYBOARD=${4:-desktop}
TM_STATE=${GBOS_TABLET_STATE_DIR:-/data/local/tmp/gbos-tablet}
TM_RUN=${GBOS_TABLET_RUN_DIR:-/dev/gbos-tablet}
TM_INPUT_DEVICES=${GBOS_INPUT_DEVICES:-/proc/bus/input/devices}
TM_SYS=${GBOS_SYSFS_ROOT:-/sys}
TM_POLL=${GBOS_TABLET_POLL:-30}
TM_FAST_POLLS=${GBOS_TABLET_FAST_POLLS:-30}
TM_MODE_POLL=${GBOS_TABLET_MODE_POLL:-3}

tm_log() { echo "$(date '+%H:%M:%S') $*" >> "$TM_OUT"; }

# Switch-capable input devices: "/dev/input/eventN kinds name", kinds = lid,tablet / lid / tablet / other.
# B: SW= is a hex bitmap; SW_LID = bit 0, SW_TABLET_MODE = bit 1, so the last hex digit is enough.
tm_switch_devices() {
  awk '
    function flush() {
      if (h != "" && sw != "") {
        c = substr(sw, length(sw), 1); k = ""
        if (index("13579bdfBDF", c)) k = "lid"
        if (index("2367abefABEF", c)) k = (k == "" ? "tablet" : k ",tablet")
        if (k == "") k = "other"
        print "/dev/input/" h, k, name
      }
      h = ""; sw = ""; name = ""
    }
    /^I:/ { flush() }
    /^N: Name=/ { name = substr($0, 9) }
    /^H: Handlers=/ { s = $0; sub(/^H: Handlers=/, "", s); n = split(s, f, " "); for (i = 1; i <= n; i++) if (f[i] ~ /^event[0-9]+$/) h = f[i] }
    /^B: SW=/ { sw = substr($0, 7); sub(/[ \t]+$/, "", sw); m = split(sw, w, " "); sw = w[m] }
    END { flush() }
  ' "$TM_INPUT_DEVICES" 2>/dev/null
}

tm_tablet_device() { tm_switch_devices | awk '$2 ~ /tablet/ { print $1; exit }'; }

# 1 (tablet), 0 (cover attached) or "unknown" from the hex switch bits getevent -qS prints.
tm_tablet_state() {
  _dev=${1:-$(tm_tablet_device)}
  [ -n "$_dev" ] || { echo unknown; return 0; }
  # Android's toolbox prints only the bits ("0002") for one device; accept an optional "<device>: " prefix too.
  _bits=$(getevent -qS "$_dev" 2>/dev/null | sed -n 's/^\(.*:\)\{0,1\}[[:space:]]*\([0-9a-fA-F]\{1,8\}\)[[:space:]]*$/\2/p' | tail -n 1)
  [ -n "$_bits" ] || { echo unknown; return 0; }
  case $(printf '%s' "$_bits" | tail -c 1) in
    2|3|6|7|a|b|e|f|A|B|E|F) echo 1 ;;
    *) echo 0 ;;
  esac
}

tm_device_state() {
  timeout 10 dumpsys device_state 2>&1 | grep -E 'mCommittedState|mBaseState|mPendingState' | sed 's/^[[:space:]]*//' | tr '\n' ' '
}

# ROTATION=1: re-apply the display-0 policy whenever it is not "disabled". $1 = why we looked.
tm_rotation_check() {
  [ "$TM_ROTATION" = 1 ] || return 0
  _mode=$(echo $(cmd window fixed-to-user-rotation 2>&1))
  [ "$_mode" = disabled ] && return 0
  if cmd window fixed-to-user-rotation disabled >/dev/null 2>&1; then
    tm_log "rotation: fixed-to-user-rotation was '$_mode' ($1); re-applied disabled, now '$(echo $(cmd window fixed-to-user-rotation 2>&1))'; user-rotation: $(echo $(cmd window user-rotation 2>&1))"
  else
    tm_log "rotation: ERROR: fixed-to-user-rotation was '$_mode' ($1) and cmd window fixed-to-user-rotation disabled failed"
    return 1
  fi
}

# Android users. On this build user 0 is the headless system user and the desktop user (10) starts at login, after this
# helper's first run (boot 26, 2026-11-26: the setting went to user 0 only, so user 10 never got the on-screen keyboard).
tm_users() {
  _u=$(pm list users 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p')
  echo "${_u:-0}"
}
tm_ime_get() { settings --user "${1:-current}" get secure show_ime_with_hard_keyboard 2>/dev/null; }

# show_ime_with_hard_keyboard=1 for every user, the previous value saved once per user. Re-run by the slow poll while in
# tablet mode, so a user that starts later (or a reset by Android) gets it too; logs only what it changed.
tm_ime_on_all() {
  for _u in $(tm_users); do
    _cur=$(tm_ime_get "$_u")
    [ -f "$TM_STATE/ime_saved.$_u" ] || echo "${_cur:-null}" > "$TM_STATE/ime_saved.$_u" ||
      tm_log "keyboard: ERROR: cannot save show_ime_with_hard_keyboard of user $_u"
    [ "$_cur" = 1 ] && continue
    if settings --user "$_u" put secure show_ime_with_hard_keyboard 1; then
      tm_log "keyboard: tablet: user $_u show_ime_with_hard_keyboard=1 (saved '$(cat "$TM_STATE/ime_saved.$_u" 2>/dev/null)')"
    else
      tm_log "keyboard: ERROR: settings put --user $_u show_ime_with_hard_keyboard 1 failed"
    fi
  done
}

# Puts back every saved value. $1 = the mode named in the log (laptop or desktop).
tm_ime_restore_all() {
  # Before 2026-11-27 the value was saved for the current user (user 0 at that point) in ime_saved.
  [ -f "$TM_STATE/ime_saved" ] && mv -f "$TM_STATE/ime_saved" "$TM_STATE/ime_saved.0"
  for _f in "$TM_STATE"/ime_saved.*; do
    [ -f "$_f" ] || continue
    _u=${_f##*.}; _v=$(cat "$_f" 2>/dev/null)
    case "$_v" in
      0|1) settings --user "$_u" put secure show_ime_with_hard_keyboard "$_v" ;;
      *) settings --user "$_u" delete secure show_ime_with_hard_keyboard >/dev/null ;;
    esac && rm -f "$_f" &&
      tm_log "keyboard: $1: user $_u show_ime_with_hard_keyboard restored to '${_v:-null}'"
  done
}

tm_keyboard_tablet() {
  case "$TM_KEYBOARD" in
    ime) tm_ime_on_all ;;
    unbind)
      for _p in "$TM_SYS"/bus/serio/devices/serio*; do
        [ -e "$_p/drvctl" ] || continue
        case $(readlink "$_p/driver" 2>/dev/null) in */atkbd) ;; *) continue ;; esac
        # serio compares with strncmp(buf, "none", count): a trailing newline makes the write fail (EINVAL).
        printf manual > "$_p/bind_mode" 2>/dev/null
        if printf none > "$_p/drvctl" 2>/dev/null; then
          grep -qx "${_p##*/}" "$TM_STATE/atkbd_ports" 2>/dev/null || echo "${_p##*/}" >> "$TM_STATE/atkbd_ports"
          tm_log "keyboard: tablet: atkbd detached from ${_p##*/} ($(cat "$_p/description" 2>/dev/null))"
        else
          tm_log "keyboard: ERROR: cannot detach atkbd from ${_p##*/}"
        fi
      done
      ;;
  esac
}

# Also runs at start-up in laptop state, so a reboot while in tablet mode cannot leave the setting changed.
# $1 = the mode named in the log (default laptop).
tm_keyboard_laptop() {
  tm_ime_restore_all "${1:-laptop}"
  if [ -f "$TM_STATE/atkbd_ports" ]; then
    _left=
    for _n in $(cat "$TM_STATE/atkbd_ports"); do
      _p=$TM_SYS/bus/serio/devices/$_n
      if [ -e "$_p/driver" ] || printf atkbd > "$_p/drvctl" 2>/dev/null; then
        printf auto > "$_p/bind_mode" 2>/dev/null
        tm_log "keyboard: ${1:-laptop}: atkbd bound to $_n"
      else
        _left="$_left $_n"
        tm_log "keyboard: ERROR: cannot bind atkbd to $_n"
      fi
    done
    if [ -n "$_left" ]; then echo $_left | tr ' ' '\n' > "$TM_STATE/atkbd_ports"; else rm -f "$TM_STATE/atkbd_ports"; fi
  fi
  return 0
}

# External keyboards: USB (bus 0003) or Bluetooth (0005) input devices with a kbd handler and the letter keys
# (KEY_Q..KEY_P = bits 16-25, KEY_A..KEY_L = 30-38, all in the last word of "B: KEY="). That leaves out mice, consumer
# control, power buttons, the pen and the EC's own i8042 keyboard. Prints one name per line.
tm_ext_keyboards() {
  awk '
    function bit(w, b,   c, v) {
      if (int(b / 4) >= length(w)) return 0
      c = substr(w, length(w) - int(b / 4), 1)
      v = index("0123456789abcdef", tolower(c)) - 1
      return int(v / (2 ^ (b % 4))) % 2
    }
    function letters(w,   b) {
      for (b = 16; b <= 25; b++) if (!bit(w, b)) return 0
      for (b = 30; b <= 38; b++) if (!bit(w, b)) return 0
      return 1
    }
    function flush() {
      if ((bus == "0003" || bus == "0005") && kbd && key != "" && letters(key)) print name
      bus = ""; kbd = 0; key = ""; name = ""
    }
    /^I:/ { flush(); s = $0; sub(/.*Bus=/, "", s); bus = substr(s, 1, 4) }
    /^N: Name=/ { name = substr($0, 9) }
    /^H: Handlers=/ { if ($0 ~ /[= ]kbd( |$)/) kbd = 1 }
    /^B: KEY=/ { s = $0; sub(/^B: KEY=/, "", s); sub(/[ \t]+$/, "", s); m = split(s, w, " "); key = w[m] }
    END { flush() }
  ' "$TM_INPUT_DEVICES" 2>/dev/null
}

# laptop (cover attached), tablet (cover off), desktop (cover off and an external keyboard with EXT_KEYBOARD=desktop),
# or unknown (switch not readable).
tm_mode() {
  _sw=$(tm_tablet_state "$TM_DEV")
  case "$_sw" in
    0) echo laptop ;;
    1) if [ "$TM_EXT_KEYBOARD" = desktop ] && [ -n "$(tm_ext_keyboards)" ]; then echo desktop; else echo tablet; fi ;;
    *) echo unknown ;;
  esac
}

# Desktop mode = Android's laptop device state (2: lid open, no tablet; DesktopDeviceStateProvider), requested with
# "cmd device_state state 2" (the shell command's request token lives in system_server, so it stays after cmd exits).
# The request is ours only while $TM_RUN/override exists; "state reset" gives the switch back to Android.
TM_DESKTOP_STATE=${GBOS_TABLET_DESKTOP_STATE:-2}
tm_override_on() {
  if _o=$(cmd device_state state "$TM_DESKTOP_STATE" 2>&1); then
    : > "$TM_RUN/override"
    tm_log "desktop: requested device state $TM_DESKTOP_STATE: $(echo $_o); device_state: $(tm_device_state)"
  else
    tm_log "desktop: ERROR: cmd device_state state $TM_DESKTOP_STATE failed: $(echo $_o)"
  fi
}
tm_override_off() {
  [ -f "$TM_RUN/override" ] || return 0
  if _o=$(cmd device_state state reset 2>&1); then
    rm -f "$TM_RUN/override"
    tm_log "desktop: device state request reset: $(echo $_o); device_state: $(tm_device_state)"
  else
    tm_log "desktop: ERROR: cmd device_state state reset failed: $(echo $_o)"
  fi
}

# Act only on a change of mode (the last applied one lives in $TM_RUN, a per-boot tmpfs). $1 = why.
tm_apply_mode() {
  _st=$(tm_mode)
  [ "$_st" = unknown ] && return 1
  _last=$(cat "$TM_RUN/mode" 2>/dev/null) || _last=
  [ "$_st" = "$_last" ] && return 1
  echo "$_st" > "$TM_RUN/mode"
  _kb=$(tm_ext_keyboards | tr '\n' ',' | sed 's/,$//')
  tm_log "switch: mode $_st (was ${_last:-unset}, $1); SW_TABLET_MODE=$(tm_tablet_state "$TM_DEV"); external keyboards: ${_kb:-none}; device_state: $(tm_device_state)"
  case "$_st" in
    laptop) tm_override_off; tm_keyboard_laptop laptop ;;
    tablet) tm_override_off; tm_keyboard_tablet ;;
    desktop) tm_keyboard_laptop desktop; tm_override_on ;;
  esac
  return 0
}

# Slow-poll upkeep of the applied mode: in tablet mode give a user that started later the on-screen keyboard; in desktop
# mode request the state again if Android dropped the request (the device is back in TABLET).
tm_keep_mode() {
  case $(cat "$TM_RUN/mode" 2>/dev/null) in
    tablet) [ "$TM_KEYBOARD" = ime ] && tm_ime_on_all ;;
    desktop)
      case $(tm_device_state) in
        *"mCommittedState=Optional[DeviceState{identifier=$TM_DESKTOP_STATE,"*) ;;
        *) rm -f "$TM_RUN/override"; tm_log "desktop: device state request lost; again"; tm_override_on ;;
      esac
      ;;
  esac
}

# After a switch change Android commits the new device state and LaptopController runs about a second later.
tm_after_event() {
  tm_apply_mode "$1"
  for _d in 1 2 3; do
    sleep "$_d"
    tm_rotation_check "$1 +${_d}s"
  done
}

tm_report() {
  echo "Latitude 7320 tablet mode helper: $(date '+%Y-%m-%d %H:%M:%S %z') rotation=$TM_ROTATION keyboard=$TM_KEYBOARD external-keyboard=$TM_EXT_KEYBOARD"
  echo "== chassis_type=$(cat "$TM_SYS/class/dmi/id/chassis_type" 2>/dev/null) intel_hid enable_sw_tablet_mode=$(cat "$TM_SYS/module/intel_hid/parameters/enable_sw_tablet_mode" 2>/dev/null || echo '(intel_hid not loaded)')"
  echo "== switch devices (device kinds name)"; tm_switch_devices
  echo "== getevent -S (device: switch bits; SW_LID=1, SW_TABLET_MODE=2)"; getevent -qS 2>&1
  echo "== dumpsys device_state"; timeout 10 dumpsys device_state 2>&1 | head -n 60
  echo "== settings"
  for _u in $(tm_users); do echo "user $_u show_ime_with_hard_keyboard=$(tm_ime_get "$_u")"; done
  echo "external keyboards: $(tm_ext_keyboards | tr '\n' ',' | sed 's/,$//')"
  echo "fixed-to-user-rotation=$(echo $(cmd window fixed-to-user-rotation 2>&1)) user-rotation=$(echo $(cmd window user-rotation 2>&1))"
  echo "config.override_forced_orient=$(getprop config.override_forced_orient)"
  echo "== events"
}

tm_watch() {
  while true; do
    getevent -qc 1 "$1" > /dev/null 2>&1 || { tm_log "watch: getevent on $1 failed; stopped watching it"; return 1; }
    tm_after_event "event on $1"
  done
}

tm_main() {
  mkdir -p "${TM_OUT%/*}" "$TM_STATE" "$TM_RUN" || exit 1
  tm_report >> "$TM_OUT" 2>&1
  TM_DEV=$(tm_tablet_device)
  if [ -n "$TM_DEV" ]; then
    tm_apply_mode "start" || tm_log "switch: start state $(tm_tablet_state "$TM_DEV") on $TM_DEV"
  else
    tm_log "switch: no SW_TABLET_MODE device (intel_hid switches missing: see hwdetect.txt); keyboard handling off"
    tm_keyboard_laptop
  fi
  tm_rotation_check "start"
  for _w in $(tm_switch_devices | awk '{ print $1 }'); do
    tm_watch "$_w" &
  done
  # Fast at first (LaptopController's boot-time reset arrived 1.4 s after boot_completed on boot-9), then slow. A keyboard
  # plugged in or out sends no switch event: the mode (switch + /proc/bus/input/devices) is read every TM_MODE_POLL s.
  _i=0; _t=0
  while true; do
    if [ "$_i" -lt "$TM_FAST_POLLS" ]; then
      sleep 2; _i=$((_i + 1))
      [ -n "$TM_DEV" ] && tm_apply_mode "poll"
      tm_rotation_check "poll"
    else
      sleep "$TM_MODE_POLL"; _t=$((_t + TM_MODE_POLL))
      [ -n "$TM_DEV" ] && tm_apply_mode "poll"
      if [ "$_t" -ge "$TM_POLL" ]; then
        _t=0
        [ -n "$TM_DEV" ] && tm_keep_mode
        tm_rotation_check "poll"
      fi
    fi
  done
}

[ "${GBOS_TABLET_MODE_LIB:-0}" = 1 ] || tm_main
