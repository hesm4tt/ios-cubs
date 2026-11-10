B=/sys/firmware/devicetree/base
echo "psci method: $(cat $B/psci/method 2>/dev/null | tr '\0' ' ') compatible: $(cat $B/psci/compatible 2>/dev/null | tr '\0' ' ')"
for c in $B/cpus/cpu@*; do echo "$(basename $c) reg=$(od -An -tx1 -v $c/reg | tr -d '\n') enable-method=$(cat $c/enable-method 2>/dev/null | tr '\0' ' ') phandle=$(od -An -tx1 -v $c/phandle 2>/dev/null | tr -d ' \n') cap=$(od -An -tx1 -v $c/capacity-dmips-mhz 2>/dev/null | tr -d ' \n')"; done
g=$(ls -d $B/interrupt-controller@* 2>/dev/null | head -1); echo "gic node: $g"
for f in compatible reg '#redistributor-regions' redistributor-stride; do echo "$f: $(od -An -tx1 -v $g/$f 2>/dev/null | tr -d '\n' | cut -c1-200)"; done
grep -i -E "gic|ppi" /proc/interrupts | head -4 | cut -c1-120
cat /sys/devices/system/cpu/online
