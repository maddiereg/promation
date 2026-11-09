#!/usr/bin/env bash
# Promation build script.
#   ./build.sh            debug build of the app       -> build/promation
#   ./build.sh release    optimised build of the app
#   ./build.sh test       headless renderer test        -> build/render_test.png
#   ./build.sh check      type-check everything
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
mkdir -p build/shaders

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
		odin test src/render -out:build/render_unit_tests "${FLAGS[@]}"
		odin build src/tools/render_test -out:build/render_test -debug "${FLAGS[@]}"
		./build/render_test build/render_test.png "${2:-1}"
		;;
	check)
		odin check src/render -no-entry-point "${FLAGS[@]}"
		odin check src/tools/render_test "${FLAGS[@]}"
		odin check src/app "${FLAGS[@]}"
		;;
	*) echo "unknown mode: $MODE"; exit 1 ;;
esac
