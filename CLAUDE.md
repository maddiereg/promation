# Promation

Open-source 2D animation app in the spirit of Moho Pro: vector drawing, bones,
timeline animation. GPL-3.0-or-later. The roadmap and decisions are in
`docs/PLAN.md`; each phase has its own notes (`docs/phase0.md`,
`docs/phase2.md`, ...). Read `docs/PLAN.md` before starting a phase.

## Status

Phases 0–2 are done and merged into `main` (tests, foundations, vector
drawing). Next is Phase 3: animation (channels, timeline UI, playback,
onion skin).

## Stack

- Odin (dev-2026-10), SDL3 via `vendor:sdl3`, SDL_GPU (Vulkan on Linux).
- Dear ImGui docking branch through the Capati odin-imgui bindings in
  `third_party/odin-imgui`, imported with `-collection:third=third_party`
  as `im "third:odin-imgui"`. The static library is built by
  `scripts/build_imgui.sh` and is not in git.
- Shaders in `shaders/` are compiled to SPIR-V by `glslc` in `build.sh` and
  embedded with `#load`. macOS (MSL) shaders are not done yet.
- Dev machine: Arch Linux, KDE on Wayland, AMD GPU (RADV), Wacom Intuos
  CTH-680 pen with eraser.

## Layout

- `src/core` — document model, generational handles (`pool.odin`), undo
  (`history.odin`), curves and geometry (`curves.odin`), pure
  `evaluate(doc, preview)`, JSON project files. **Must not import SDL, ImGui
  or anything platform-specific**: it is shared with the future Android app
  and must keep building with `./build.sh android-core`.
- `src/render` — vector renderer (flatten → stencil-then-cover, 4x MSAA,
  premultiplied alpha) on SDL_GPU.
- `src/app` — desktop app: SDL events, ImGui panels (`ui.odin`), tools
  (`tools.odin`), canvas overlays (`overlay.odin`), freehand strokes
  (`canvas.odin`), open/save (`project_io.odin`).
- `src/tools/render_test` — headless renderer test that writes a PNG.

## Commands

```bash
./build.sh                 # debug build -> build/promation
./build.sh release         # optimised build
./build.sh test            # core + render unit tests, then headless render test
./build.sh check           # type-check every package
ODIN_ANDROID_NDK=~/Android/Sdk/ndk/28.2.13676358 ./build.sh android-core
./build/promation          # run the app
```

Before handing work over: `./build.sh`, `./build.sh test` (all tests pass,
no leaks reported by the memory tracker) and, when `src/core` changed, the
`android-core` build.

## Code conventions

- Every document edit goes through `history.odin` commands so it can be
  undone. Edits that touch several objects go inside
  `history_begin_group` / `history_end_group`. A drag recomputes from a
  snapshot every frame inside a group with one merge key, so the whole drag
  is one undo step (drag keys start at `1 << 48`, style edits use
  `1 << 40 | field`).
- Deleted objects stay in their pool, unlinked, so undo can bring them back.
- `evaluate` stays pure; tools show unfinished work through `pm.Preview`.
- Add tests in `src/core/*_test.odin` for core behaviour.
- Odin binding quirks: `im.Vec2` is a struct `{x, y}`, not an array; draw
  list procs are prefixed (`im.DrawList_AddLine(dl, ...)`); ImGui works in
  window points, so pixel positions are divided by `app.density`.
- Procs called at global scope must be `"contextless"`.

## Known issues

- SDL 3.4.18 on Wayland often delivers no pen pressure (`PEN_AXIS`) for a
  stroke. Strokes then use full width until the first pressure reading;
  the per-stroke `pen stroke:` log line shows it (`pressure_events=0`).
  Not our bug; an upstream report is still to be filed.
- Zenity prints Gtk theme warnings (klassy-dark) when the file dialog opens.
  Harmless.

## How we work

- The user tests the UI themselves and reports back; Claude cannot see the
  app window. After a change, build, run the tests and ask the user to try it
  with `./build.sh && ./build/promation`, saying what to check.
- One branch per phase (`phase-3`, ...), merged into `main` when the user is
  happy. Commit, merge and push only when the user asks.
- Commit messages end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Remote: `git@github.com:maddiereg/promation.git`. The SSH key
  (`~/.ssh/maddieregt14`, set in `core.sshCommand`) has a passphrase, so run
  `git push` in a terminal tab where the user can type it.
- Update `docs/PLAN.md` and the phase notes when a phase starts or ends.
