export PATH=$PATH:/opt/homebrew/bin
N=/opt/homebrew/share/android-ndk; T=$N/toolchains/llvm/prebuilt/darwin-x86_64
cd ~/vk && $T/bin/aarch64-linux-android31-clang -O2 -o drmfb drmfb.c && adb push drmfb /data/local/tmp/drmfb2 >/dev/null
printf 'RAMOFF=28b4000 LISTOFF=17fe00000 WAIT=200 sh /data/local/tmp/amp_gpu.sh\n' > ~/run_gpu.sh
adb push ~/run_gpu.sh /data/local/tmp/run_gpu.sh >/dev/null
adb push ~/pcwork/hopay2/tex2r.payload /data/local/tmp/ho.payload >/dev/null
adb push ~/pcwork/handover/cubs_stage.ko /data/local/tmp/cubs_stage.ko >/dev/null
adb push ~/gpusrv/target/aarch64-linux-android/release/mtlsrv /data/local/tmp/mtlsrv >/dev/null
adb push ~/glsrv /data/local/tmp/glsrv >/dev/null
adb push ~/amp_gpu.sh /data/local/tmp/amp_gpu.sh >/dev/null
adb shell 'rm -f /data/local/tmp/amp_gpu.log /data/local/tmp/fbdump.raw; sync; echo "nohup sh /data/local/tmp/run_gpu.sh >/data/local/tmp/run_gpu.out 2>&1 &" | /data/adb/ksu/bin/ksud debug su'
echo started
