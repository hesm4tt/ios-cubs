for c in 0 1 2 3 4 5 6; do
  d=/sys/devices/system/cpu/cpu$c
  echo "cpu$c online=$(cat $d/online 2>/dev/null) cap=$(cat $d/cpu_capacity 2>/dev/null) cur=$(cat $d/cpufreq/scaling_cur_freq 2>/dev/null) min=$(cat $d/cpufreq/cpuinfo_min_freq 2>/dev/null) max=$(cat $d/cpufreq/cpuinfo_max_freq 2>/dev/null) gov=$(cat $d/cpufreq/scaling_governor 2>/dev/null) midr=$(cat $d/regs/identification/midr_el1 2>/dev/null) mpidr=$(cat $d/regs/identification/mpidr_el1 2>/dev/null)"
done
ls /sys/devices/system/cpu/cpufreq/
for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "$p cpus=$(cat $p/related_cpus) avail=$(cat $p/scaling_available_frequencies 2>/dev/null | cut -c1-120)"; done
