#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
home_dir="$test_tmp/home"
iio_dir="$test_tmp/iio"
rotate_log="$test_tmp/rotate.log"

mkdir -p "$stub_bin" "$home_dir" "$iio_dir"

# ---- omarchy-hw-accelerometer ----

hw_accelerometer() {
  OMARCHY_IIO_PATH="$iio_dir" bash "$ROOT/bin/omarchy-hw-accelerometer"
}

if hw_accelerometer; then
  fail "accelerometer detection finds nothing on an empty IIO tree"
fi
pass "accelerometer detection finds nothing on an empty IIO tree"

# A light sensor is an IIO device too, and is not something to rotate a screen by.
mkdir -p "$iio_dir/iio:device0"
touch "$iio_dir/iio:device0/in_illuminance_raw"
if hw_accelerometer; then
  fail "accelerometer detection ignores other IIO sensors"
fi
pass "accelerometer detection ignores other IIO sensors"

mkdir -p "$iio_dir/iio:device1"
touch "$iio_dir/iio:device1/in_accel_x_raw"
hw_accelerometer || fail "accelerometer detection finds a polled accelerometer"
pass "accelerometer detection finds a polled accelerometer"

rm -rf "$iio_dir/iio:device1"
mkdir -p "$iio_dir/iio:device2/scan_elements"
touch "$iio_dir/iio:device2/scan_elements/in_accel_x_en"
hw_accelerometer || fail "accelerometer detection finds a buffer-only accelerometer"
pass "accelerometer detection finds a buffer-only accelerometer"

# ---- omarchy-display-autorotate ----

cat >"$stub_bin/omarchy-hw-accelerometer" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/omarchy-cmd-present" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/omarchy-hyprland-monitor-laptop" <<'SH'
#!/bin/bash
echo eDP-1
SH

cat >"$stub_bin/omarchy-toggle-enabled" <<'SH'
#!/bin/bash
[[ -f "$HOME/.local/state/omarchy/toggles/$1" ]]
SH

cat >"$stub_bin/hyprctl" <<'SH'
#!/bin/bash
[[ $1 == "monitors" && $2 == "-j" ]] || exit 1
if [[ ${OMARCHY_TEST_INTERNAL_ENABLED:-true} == "true" ]]; then
  printf '[{"name":"eDP-1"}]'
else
  printf '[{"name":"DP-2"}]'
fi
SH

cat >"$stub_bin/omarchy-display-orientation" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_ROTATE_LOG"
SH

# The sensor stream the daemon reads, replayed verbatim from monitor-sensor.
cat >"$stub_bin/monitor-sensor" <<'SH'
#!/bin/bash
if [[ ${OMARCHY_TEST_STATIC_SENSOR:-false} == "true" ]]; then
  echo '=== Has accelerometer (orientation: left-up)'
  sleep 10
  exit 0
fi

cat <<'OUT'
    Waiting for iio-sensor-proxy to appear
+++ iio-sensor-proxy appeared
=== Has accelerometer (orientation: normal)
=== No ambient light sensor
    Accelerometer orientation changed: left-up
    Accelerometer orientation changed: bottom-up
    Accelerometer orientation changed: right-up
    Accelerometer orientation changed: undefined
OUT

# The real monitor-sensor holds the sensor open for the session. Stay open too,
# so the daemon's reconnect loop doesn't replay the stream while the test reads it.
sleep 10
SH

chmod +x "$stub_bin"/*

# Runs the daemon against the replayed stream until it has logged the rotations
# expected of it, then stops it. The daemon is a session-long loop, so there is
# no exit to wait for; a run that logs nothing waits out the grace period.
autorotate() {
  local expected_lines="$1" pid waited=0 runtime_dir

  : >"$rotate_log"

  # A fresh runtime dir per run: the daemon holds a flock for the length of the
  # session, and a run that inherited a still-held lock would exit at once and
  # look like a daemon that decided not to rotate anything.
  runtime_dir=$(mktemp -d "$test_tmp/runtime.XXXXXX")

  HOME="$home_dir" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    OMARCHY_TEST_ROTATE_LOG="$rotate_log" \
    OMARCHY_IIO_PATH="$iio_dir" \
    PATH="$stub_bin:$PATH" \
    bash "$ROOT/bin/omarchy-display-autorotate" >/dev/null 2>&1 &
  pid=$!

  while (( waited < 50 )); do
    (( $(wc -l <"$rotate_log") >= expected_lines )) && (( expected_lines > 0 )) && break
    sleep 0.1
    (( ++waited ))
    (( expected_lines == 0 )) && (( waited >= 15 )) && break
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Nothing the daemon started may outlive it: a monitor-sensor left behind keeps
# iio-sensor-proxy polling, and every restart would add another one.
sensor_children() {
  pgrep -c -f "$stub_bin/monitor-sensor" 2>/dev/null || true
}

autorotate 4

expected='0 --monitor eDP-1 --transient
1 --monitor eDP-1 --transient
2 --monitor eDP-1 --transient
3 --monitor eDP-1 --transient'

[[ $(cat "$rotate_log") == "$expected" ]] ||
  fail "autorotate maps every sensor orientation onto a Hyprland transform" \
    "expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$(cat "$rotate_log")"
pass "autorotate maps every sensor orientation onto a Hyprland transform"
pass "autorotate ignores an orientation the sensor cannot name"

mkdir -p "$home_dir/.local/state/omarchy/toggles"
touch "$home_dir/.local/state/omarchy/toggles/rotate-lock"
autorotate 0
[[ ! -s $rotate_log ]] ||
  fail "autorotate stays put while rotate lock is on" "actual:"$'\n'"$(cat "$rotate_log")"
pass "autorotate stays put while rotate lock is on"
rm -f "$home_dir/.local/state/omarchy/toggles/rotate-lock"

# Nothing to rotate when the panel is off: the accelerometer still reports, but
# the display it speaks for is not on screen.
OMARCHY_TEST_INTERNAL_ENABLED=false
export OMARCHY_TEST_INTERNAL_ENABLED
autorotate 0
[[ ! -s $rotate_log ]] ||
  fail "autorotate leaves a disabled panel alone" "actual:"$'\n'"$(cat "$rotate_log")"
pass "autorotate leaves a disabled panel alone"
unset OMARCHY_TEST_INTERNAL_ENABLED

# Transient rules disappear on a Hyprland reload, which does not itself make
# monitor-sensor emit another event. Replaying the last reading repairs both
# the panel and input transforms without waiting for the laptop to move.
OMARCHY_TEST_STATIC_SENSOR=true
OMARCHY_AUTOROTATE_VERIFY_INTERVAL=0.1
export OMARCHY_TEST_STATIC_SENSOR OMARCHY_AUTOROTATE_VERIFY_INTERVAL
autorotate 2
(( $(grep -c '^1 --monitor eDP-1 --transient$' "$rotate_log") >= 2 )) ||
  fail "autorotate reapplies the current orientation after a compositor reload"
pass "autorotate periodically verifies the current orientation"
unset OMARCHY_TEST_STATIC_SENSOR OMARCHY_AUTOROTATE_VERIFY_INTERVAL

# Framework 12 exposes a labelled display accelerometer and a hinge-angle
# sensor, but monitor-sensor can remain silent when iio-sensor-proxy selects the
# device's unusable buffered interface. The direct reader is the fallback.
framework_accel="$iio_dir/iio:device3"
framework_lid="$iio_dir/iio:device4"
mkdir -p "$framework_accel" "$framework_lid"
echo accel-display >"$framework_accel/label"
echo cros-ec-accel >"$framework_accel/name"
echo -10000 >"$framework_accel/in_accel_x_raw"
echo 0 >"$framework_accel/in_accel_y_raw"
echo 0 >"$framework_accel/in_accel_z_raw"
echo cros-ec-lid-angle >"$framework_lid/name"
echo 500 >"$framework_lid/in_angl_raw"

OMARCHY_AUTOROTATE_POLL_INTERVAL=0.02
export OMARCHY_AUTOROTATE_POLL_INTERVAL
autorotate 1
[[ $(cat "$rotate_log") == '1 --monitor eDP-1 --transient' ]] ||
  fail "autorotate reads the Framework display sensor directly" \
    "actual:"$'\n'"$(cat "$rotate_log")"
pass "autorotate falls back to the Framework display sensor"

echo 113 >"$framework_lid/in_angl_raw"
autorotate 1
[[ $(cat "$rotate_log") == '0 --monitor eDP-1 --transient' ]] ||
  fail "autorotate restores normal orientation in Framework laptop mode" \
    "actual:"$'\n'"$(cat "$rotate_log")"
pass "autorotate gates rotation on the Framework hinge angle"
unset OMARCHY_AUTOROTATE_POLL_INTERVAL
rm -rf "$framework_accel" "$framework_lid"

autorotate 4
for _ in {1..30}; do
  (( $(sensor_children) == 0 )) && break
  sleep 0.1
done
(( $(sensor_children) == 0 )) ||
  fail "autorotate takes its sensor reader down with it" \
    "still running:"$'\n'"$(pgrep -a -f "$stub_bin/monitor-sensor")"
pass "autorotate takes its sensor reader down with it"
