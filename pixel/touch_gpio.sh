sed -n 5,90p /sys/kernel/debug/gpio | grep -n -E "gpio-(53[5-9]|54[0-1]|56[5-9]|57[0-2])" 
echo ---
D=/sys/kernel/debug/pinctrl/e500000.pinctrl
ls $D
grep -E "^pin (2[2-4]|5[3-5]) " $D/pins
grep -E "pin (2[2-4]|5[3-5]) " $D/pinmux-pins
grep -E "pin (2[2-4]|5[3-5]) " $D/pinconf-pins 2>/dev/null | head
