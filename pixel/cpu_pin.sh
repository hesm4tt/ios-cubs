fq=/sys/devices/system/cpu/cpufreq/policy0
echo "before cur=$(cat $fq/scaling_cur_freq) min=$(cat $fq/scaling_min_freq) max=$(cat $fq/scaling_max_freq)"
cat $fq/scaling_available_governors
echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_max_freq
echo $(cat $fq/cpuinfo_max_freq) > $fq/scaling_min_freq
sleep 1
echo "after cur=$(cat $fq/scaling_cur_freq) min=$(cat $fq/scaling_min_freq) max=$(cat $fq/scaling_max_freq) gov=$(cat $fq/scaling_governor)"
cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq 2>&1
