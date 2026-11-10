set -e
N=/opt/homebrew/share/android-ndk
T=$N/toolchains/llvm/prebuilt/darwin-x86_64
GLSLC=$(find $N/shader-tools -name glslc | head -1)
cd ~/vk
$GLSLC -mfmt=num -o vert.inc tri.vert
$GLSLC -mfmt=num -o frag.inc tri.frag
{ echo "static const unsigned vert_spv[] = {"; cat vert.inc; echo "};"; } > vert.h
{ echo "static const unsigned frag_spv[] = {"; cat frag.inc; echo "};"; } > frag.h
$T/bin/aarch64-linux-android31-clang -O2 -o tri tri.c -lvulkan
echo built
