for d in /vendor_dlkm/lib/modules /system_dlkm/lib/modules /vendor/lib/modules; do ls $d 2>/dev/null | grep -i -E "pin|gpio|mbu" | sed "s#^#$d/#"; done
grep -i -E "pinctrl.*(goog|mbu|aoss)|mbu_|goog_pin|gpio_goog" /proc/kallsyms | head -20
