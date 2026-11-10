q=/sys/firmware/devicetree/base/pinctrl@E500000
echo "compatible: $(cat $q/compatible | tr '\0' ' ')"
for f in $q/*; do n=$(basename $f); [ -f $f ] && echo "$n: $(od -An -tx1 -v $f | head -3 | tr -d '\n' | cut -c1-200)"; done | head -40
ls $q | head -30
