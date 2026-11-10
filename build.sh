#!/usr/bin/env bash
# Promation build script.
#   ./build.sh            debug build of the app       -> build/promation
#   ./build.sh release    optimised build of the app
#   ./build.sh test       headless renderer test        -> build/render_test.png
#   ./build.sh check      type-check everything
#   ./build.sh android-core  cross-compile the core for Android arm64
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
mkdir -p build/shaders build/android

# Shaders -> SPIR-V (embedded into the binary with #load).
for s in shaders/*.vert shaders/*.frag; do
	out="build/shaders/$(basename "$s").spv"
	if [ ! -f "$out" ] || [ "$s" -nt "$out" ]; then
		glslc -O "$s" -o "$out"
	fi
done

FLAGS=(-vet -strict-style -collection:third=third_party)
case "$MODE" in
	debug)   odin build src/app -out:build/promation -debug "${FLAGS[@]}" ;;
	release) odin build src/app -out:build/promation -o:speed "${FLAGS[@]}" ;;
	test)
		odin test src/core -out:build/core_unit_tests "${FLAGS[@]}"
		odin test src/render -out:build/render_unit_tests "${FLAGS[@]}"
		odin build src/tools/render_test -out:build/render_test -debug "${FLAGS[@]}"
		./build/render_test build/render_test.png "${2:-1}"
		;;
	check)
		odin check src/core -no-entry-point "${FLAGS[@]}"
		odin check src/render -no-entry-point "${FLAGS[@]}"
		odin check src/tools/render_test "${FLAGS[@]}"
		odin check src/app "${FLAGS[@]}"
		;;
	android-core)
		# The core must keep compiling for Android; run with ODIN_ANDROID_NDK set.
		odin build src/core -build-mode:obj -target:linux_arm64 -subtarget:android -no-entry-point -out:build/android/core.o "${FLAGS[@]}"
		;;
	*) echo "unknown mode: $MODE"; exit 1 ;;
esac
