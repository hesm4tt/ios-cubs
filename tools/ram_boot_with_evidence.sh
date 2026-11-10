#!/usr/bin/env bash
# Run a hashed, RAM-only Fastboot boot and retain post-boot evidence as soon as
# authorized ADB returns. Usage: ram_boot_with_evidence.sh CPDIR SHA256 [SECONDS]
set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	echo "usage: $0 CPDIR SHA256 [SECONDS]" >&2
	exit 2
fi

serial=<adb-serial>
project="$HOME/unixnu-pixel11/cubs-xnu-bootstrap"
checkpoint_dir="$project/out/checkpoints/$1"
expected_sha="$2"
watch_seconds="${3:-150}"
image="$checkpoint_dir/cubs-xnu-ram-boot.img"
runner="$project/direct-xnu-checkpoint10/ram_boot_candidate.py"
adb=/opt/homebrew/bin/adb
fastboot=/opt/homebrew/bin/fastboot

if [ ! -f "$image" ]; then
	echo "missing boot image: $image" >&2
	exit 2
fi
actual_sha=$(shasum -a 256 "$image" | awk '{print $1}')
if [ "$actual_sha" != "$expected_sha" ]; then
	echo "image SHA-256 mismatch: $actual_sha" >&2
	exit 2
fi

echo "run_start=$(date '+%Y-%m-%dT%H:%M:%S%z') checkpoint=$1 image_sha256=$actual_sha"
/opt/homebrew/bin/python3 "$runner" "$image" "$checkpoint_dir/ram-boot.log" "$expected_sha"
runner_status=$?
echo "runner_exit=$runner_status at=$(date '+%Y-%m-%dT%H:%M:%S%z')"

observation_log="$checkpoint_dir/usb-observation.log"
: > "$observation_log"
post_boot="$checkpoint_dir/post-boot"
mkdir -p "$post_boot"
start_seconds=$(date +%s)
deadline=$((start_seconds + watch_seconds))
last_state=""
captured=0

while [ "$(date +%s)" -lt "$deadline" ]; do
	adb_status=$("$adb" devices | awk -v s="$serial" '$1 == s { print $2; exit }')
	fastboot_state=$("$fastboot" devices | awk -v s="$serial" '$1 == s { print "present"; exit }')
	usb_count=$(ioreg -p IOUSB -w0 | grep -c 'Pixel 11' || true)
	state="adb=${adb_status:-absent} fastboot=${fastboot_state:-absent} usb_pixel=$usb_count"
	elapsed=$(( $(date +%s) - start_seconds ))
	if [ "$state" != "$last_state" ]; then
		line="$(date '+%Y-%m-%dT%H:%M:%S%z') +${elapsed}s $state"
		echo "$line" | tee -a "$observation_log"
		last_state="$state"
	fi

	if [ "$adb_status" = "device" ]; then
		printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$post_boot/captured-at.txt"
		"$adb" -s "$serial" shell getprop ro.boot.bootreason > "$post_boot/bootreason.txt" 2>&1 || true
		"$adb" -s "$serial" shell getprop ro.product.device > "$post_boot/product.txt" 2>&1 || true
		"$adb" -s "$serial" shell getprop sys.boot.reason > "$post_boot/sys-boot-reason.txt" 2>&1 || true
		"$adb" -s "$serial" shell getprop persist.sys.boot.reason.history > "$post_boot/boot-reason-history.txt" 2>&1 || true
		"$adb" -s "$serial" shell cat /proc/uptime > "$post_boot/uptime.txt" 2>&1 || true
		"$adb" -s "$serial" shell ls -la /sys/fs/pstore > "$post_boot/pstore-list.txt" 2>&1 || true
		"$adb" -s "$serial" pull /sys/fs/pstore "$post_boot/pstore" > "$post_boot/pstore-pull.log" 2>&1 || true
		"$adb" -s "$serial" exec-out cat /sys/fs/pstore/console-ramoops-0 > "$post_boot/console-ramoops-0" 2> "$post_boot/pstore-console.stderr" || true
		shasum -a 256 "$post_boot"/console-ramoops-0 > "$post_boot/SHA256SUMS" 2>/dev/null || true
		echo "evidence_captured=$post_boot"
		cat "$post_boot/bootreason.txt" "$post_boot/product.txt" "$post_boot/uptime.txt"
		cat "$post_boot/pstore-list.txt"
		captured=1
		break
	fi
	sleep 1
done

if [ "$captured" -eq 0 ]; then
	echo "adb_capture_timeout=${watch_seconds}s"
fi
echo "observer_exit=$(date '+%Y-%m-%dT%H:%M:%S%z')"
exit "$runner_status"
