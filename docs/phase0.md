# Phase 0: technology tests

Goal: prove the Odin + SDL3 + SDL_GPU + Dear ImGui stack before building the editor.

## Results

| Check | Status | Notes |
|---|---|---|
| Toolchain | ✅ | Odin dev-2026-10, SDL3 3.4, glslc, Vulkan (RADV) |
| Vector renderer on GPU | ✅ | Headless test renders correctly: `./build.sh test` |
| Anti-aliasing | ✅ | 4x MSAA (8x is supported but capped for tablet bandwidth) |
| Concave and self-intersecting fills | ✅ | Stencil winding, non-zero rule |
| Variable-width strokes | ✅ | Per-sample width, round joins/caps |
| Translucency without double blending | ✅ | Overlapping translucent stroke blends once |
| Geometry unit tests | ✅ | `odin test src/render` |
| App: window + ImGui docking + canvas | ✅ | Runs on Linux/Wayland; drawing confirmed by hand |
| Pen pressure, tip (Wacom CTH-680) | 🟡 | 20/20 strokes correct in the controlled test; one earlier session lost pressure on the same tool, not reproduced or explained |
| Pen pressure, eraser end | ❌ | 0/10 strokes received any axis event (see below) |
| Tilt | ⏳ | Untested: the CTH-680 logged no tilt events |
| Odin core → Android arm64 | ✅ | `src/render` compiles for `linux_arm64 -subtarget:android`; a shared `.so` links with NDK r28 |
| Running on an Android tablet | ⏳ | Needs a device, plus SDL3 built for Android (Java glue via `SDLActivity`) |

## Renderer design

Stencil-then-cover with MSAA (`src/render/renderer.odin`):

- **Fill**: triangle fan per contour → stencil incremented/decremented by triangle facing
  (= winding number) → bounding quad drawn where stencil ≠ 0, which also resets the stencil.
- **Stroke**: segment quads + discs at every sample → stencil set to 1 → same cover quad.
- Every shape touches each sample once, so translucent shapes blend correctly.
- Curves are flattened on the CPU each frame with a quarter-pixel tolerance, so deformation
  (bones, later) costs nothing extra. Fine for the MVP; may move to compute or a
  cached tessellation if large scenes need it.
- Each shape costs 2 draw calls. Batching (or instancing the cover quads) can come later.

## Known issues / follow-ups

- **Eraser end delivers no pressure to the app (Wayland, SDL 3.4.18).** `WAYLAND_DEBUG` shows the
  compositor sending pressure for every eraser stroke, but the app receives no `PEN_AXIS` event of
  any kind for them, while `PEN_DOWN`/`PEN_MOTION` arrive normally. Reading SDL's Wayland pen code
  did not reveal why. With no pressure the stroke is drawn at the 8% minimum width.
- **Unexplained tip failures.** One session lost pressure on 14 of 31 strokes from the tip's Wayland
  tool, then recovered without the pen leaving range. A later controlled run had none. `pen stroke`
  log lines remain in debug builds so a recurrence can be diagnosed.
- Each flattened stroke point adds a full disc: 607k vertices and 22 fps on a debug build with
  269 strokes. Reduce in Phase 1.
- `vendor:sdl3` declares `GetPenDeviceType` with no return value, so it can't be
  called; the pen panel doesn't show the device type for now. Worth reporting upstream to Odin.
- Shaders are SPIR-V only (Linux/Windows Vulkan). macOS needs MSL: add SDL_shadercross
  or hand-written MSL in Phase 1.
- `scripts/build_imgui.sh` replaces odin-imgui's premake step with a plain shell script.
