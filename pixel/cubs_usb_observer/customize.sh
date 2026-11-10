#!/system/bin/sh
# KernelSU's default permissions are 0644 for files; service must be executable.
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/observe.sh" 0 0 0755
