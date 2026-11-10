#!/var/jb/bin/sh
# cubs-persist.sh: persistence and a package inbox for iOS on the Pixel. The iOS root and /var are RAM, so nothing installed survives a
# reboot by itself; this talks to persistsrv on Android (10.77.0.1:8099, keeps /data/local/ios/persist.tar and the inbox of .deb files).
#   cubs-persist.sh run    (a launchd job with a trailing &): once the server answers, restore the saved state, then every 20 s
#                          install new packages from the inbox and save the changes (files under /var/jb and /var/mobile that are
#                          newer than the moment the job started)
# Put a package in the inbox from the Mac:  adb push foo.deb /data/local/ios/inbox/   (pcwork/jb/ipa2deb.sh makes a .deb from an .ipa)
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/bin:/sbin:/usr/bin:/usr/sbin
H=http://10.77.0.1:8099
HTTP=/redwood/bin/rwhttp
B=/var/jb/.cubs-baseline
M=/var/jb/.cubs-saved
DONE=/var/jb/var/cubs-inbox

log() { echo "cubs-persist: $*"; }

restore() {
	$HTTP get $H/persist.tar /tmp/persist.tar || { log "nothing saved yet"; return; }
	# -m: the files get the time of now, so they count as changes since the baseline and are saved again
	tar -x -m -C / -f /tmp/persist.tar && log "restored $(wc -c < /tmp/persist.tar) bytes"
	rm -f /tmp/persist.tar
	reg
}

# what is kept: the whole prefix /var/jb (packages, dpkg database, apps), documents, and the preferences that are not Apple's own.
# Not the containers (their directory names change at every boot) nor caches (LaunchServices makes a 4 MB one per boot).
list_changed() {
	find /var/jb /var/mobile/Documents /var/mobile/Library/Preferences -xdev \( -type f -o -type l \) -newer "$1" \
		-not -path '*/Caches/*' -not -path '*/.cubs-*' -not -path '/var/mobile/Library/Preferences/com.apple.*' 2>/dev/null
}

# Web views draw nothing here with WebKit's accelerated drawing on (pcwork/jb/wkprobe.m, 2026-11-08): libwkfix switches it off in the programs
# that show web pages. The kernel inserts a library into programs named in kern.exec_inject (set at boot by init from inject.conf, which sits in
# the read-only root image), so a group for libwkfix is appended to what is there; programs started after this pick it up.
inject_wk() {
	lib=/var/jb/usr/lib/libwkfix.dylib
	[ -f $lib ] || return
	cur=$(sysctl -n kern.exec_inject 2>/dev/null)
	[ -n "$cur" ] || { log "kern.exec_inject unreadable, web view fix not installed"; return; }
	case "$cur" in *libwkfix*) return;; esac
	new="$cur;$lib MobileSafari SafariViewService Sileo"
	[ ${#new} -lt 500 ] || { log "kern.exec_inject too long, web view fix not installed"; return; }
	sysctl -w "kern.exec_inject=$new" >/dev/null && log "web view fix installed for Safari"
}

# lockdownd, iOS's side of pairing with a computer (Finder/iTunes): launchd binds TCP 62078 for it (its plist has the sockets); the Mac's usbmux
# reaches it through usbmuxdev on Android, which forwards port 62078 to iOS's address on the ring network. Loaded once the network is up.
start_lockdown() {
	P=/System/Library/LaunchDaemons/com.apple.mobile.lockdown.plist
	[ -f $P ] || return
	/bin/launchctl bootstrap system $P 2>&1 | head -3 || /bin/launchctl load $P
	for t in 1 2 3; do
		sleep 15
		log "lockdown: $(/bin/ps -A | grep -c '[l]ockdownd') lockdownd process(es); $(/usr/sbin/netstat -an 2>/dev/null | grep -c 62078) lines about port 62078"
	done
}

# SpringBoard only learns the apps that exist when it starts (lsprobe 2026-11-08: "application not found" until it is restarted, then the
# launch works), so after the first registration of a boot it is restarted once (it comes back in about 2 minutes)
respring_once() {
	mkdir /var/tmp/cubs-respring.lock 2>/dev/null || return
	sleep 8
	log "restarting SpringBoard so that it sees the new apps"
	killall SpringBoard
}

# register an app of the prefix with LaunchServices by its own path (LaunchServices may take a while after boot): retried in the background
reg() {
	for app in /var/jb/Applications/*.app; do
		[ -d "$app" ] || continue
		case "$app" in */Sileo.app) continue;; esac
		(
			# FrontBoard launches an app from a bundle container (/var/containers/Bundle/Application/<id>/X.app); the prefix's own
			# /var/jb/Applications is not one, so the app is copied there (real files) and registered from the container
			name=${app##*/}
			# (lsprobe 2026-11-08: an app registered from /var/jb/Applications is known to LaunchServices but SpringBoard answers
			# "application not found" when asked to launch it; the baked apps in /Applications launch. The root is read-only, so
			# the copy goes to a bundle container with a UUID-shaped name, like an App Store app)
			# 2026-11-08: registered from a bundle container the app is a "User" app and SpringBoard refuses to launch it (SBS rc 9 "security
			# policy error", the baked System apps launch); registered in place under /var/jb/Applications it is a "System" app like the baked
			# ones. SpringBoard still has to be restarted once to know it (respring_once).
			dest=/var/jb/Applications
			t=0
			while [ $t -lt 24 ]; do
				uicache -p "$dest/$name" && break
				t=$((t + 1)); sleep 5
			done
			log "registered $dest/$name (try $t)"
			[ $t -lt 24 ] && respring_once
		) &
	done
}

save() {
	[ -n "$(list_changed $M | head -n 1)" ] || return
	touch /tmp/persist.mark
	list_changed $B | sed 's#^/##' > /tmp/persist.list
	[ -s /tmp/persist.list ] || return
	tar -c -C / -T /tmp/persist.list -f /tmp/persist.tar 2>/dev/null
	if $HTTP put $H/persist.tar /tmp/persist.tar; then
		mv /tmp/persist.mark $M
		log "saved $(wc -l < /tmp/persist.list) files, $(wc -c < /tmp/persist.tar) bytes"
	fi
	rm -f /tmp/persist.tar /tmp/persist.list
}

inbox() {
	list=$($HTTP get $H/inbox.list) || return
	mkdir -p $DONE
	for n in $list; do
		[ -e "$DONE/$n" ] && continue
		$HTTP get "$H/inbox/$n" "/tmp/$n" || continue
		if dpkg -i "/tmp/$n"; then
			log "installed $n"
			touch "$DONE/$n"
			reg
		else
			log "dpkg failed for $n"
		fi
		rm -f "/tmp/$n"
	done
}

case "$1" in
run)
	touch $B $M
	# the screen brightness iOS keeps is carried to the panel's backlight (Android's) by brightbridge, which retries until persistsrv answers
	[ -x /var/jb/usr/bin/brightbridge ] && /var/jb/usr/bin/brightbridge &
	inject_wk
	until $HTTP get $H/inbox.list /dev/null 2>/dev/null; do sleep 3; done
	start_lockdown &
	restore
	while true; do
		inbox
		save
		sleep 20
	done
	;;
reg)
	# register the apps of the prefix now (a test/diagnostic entry point), wait for the background registrations
	reg
	wait
	;;
*)
	echo "usage: cubs-persist.sh run|reg"
	;;
esac
