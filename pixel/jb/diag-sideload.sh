#!/var/jb/bin/sh
# diag-sideload.sh: is the sideloaded app registered where SpringBoard finds it? Prints (lines start with "diag:") the apps in the prefix, runs the
# registration of cubs-persist.sh (copy into a bundle container + uicache -p) and lists containers and what uicache knows.
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/bin:/sbin:/usr/bin:/usr/sbin
p() { while IFS= read -r l; do echo "diag: $l"; done; }
echo "--- /var/jb/Applications" | p
ls -la /var/jb/Applications 2>&1 | p
echo "--- reg" | p
/var/jb/bin/sh /var/jb/etc/cubs-persist.sh reg 2>&1 | p
echo "--- tell SpringBoard (darwin notifications that an install posts)" | p
which notifyutil 2>&1 | p
for n in com.apple.mobile.application_installed com.apple.LaunchServices.applicationRegistered com.apple.LaunchServices.ApplicationsChanged com.apple.mobile.installation_changed; do
	notifyutil -p "$n" 2>&1 | p
done
uicache -a 2>&1 | tail -3 | p
sleep 5
echo "--- containers" | p
ls -la /var/containers/Bundle/Application/ /var/containers/Bundle/Application/*/ 2>&1 | p
echo "--- uicache -l" | p
uicache -l 2>&1 | grep -i -E "persist|metaldemo" | p
echo "done" | p
[ "$1" = respring ] && { echo "respringing SpringBoard" | p; killall SpringBoard 2>&1 | p; }
