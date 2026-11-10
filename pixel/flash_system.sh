cd /data/local/tmp
A=/dev/block/by-name/modem_a
B=/dev/block/by-name/modem_b
SA=$(blockdev --getsize64 $A)
SB=$(blockdev --getsize64 $B)
echo sizes $SA $SB
if [ "$SA" != 1454374912 ] || [ "$SB" != 1454374912 ]; then echo WRONG SIZES; exit 1; fi
N=$(wc -c < system_new.apfs)
dd if=system_new.apfs of=$A bs=1048576 count=1387
dd if=system_new.apfs of=$B bs=1048576 skip=1387
sync
echo --- verify $N
(cat $A $B | head -c $N | md5sum)
(head -c $N system_new.apfs | md5sum)
