# Promation: development plan

Open-source 2D animation software in the spirit of Moho Pro: vector drawing,
bones and keyframe animation. Desktop first; Android tablet later.
We take inspiration from the feature set only: name, branding, icons and UI are our own.

## Decisions (approved 2026-11-07)

| Topic | Decision |
|---|---|
| Language | **Odin** |
| Android | Shares the **core** codebase only, with its own touch-first front end |
| Licence | **GPL-3.0-or-later** |
| Editor UI (MVP) | **Dear ImGui** (docking branch) |
| Name | **Promation** (may change) |

## Stack

| Concern | Choice |
|---|---|
| Window, input, pen, platform | SDL3 (`vendor:sdl3`) |
| GPU | SDL_GPU (Vulkan / Metal / D3D12) |
| Vector rendering | Own renderer: flatten → stencil-then-cover, MSAA |
| UI | Dear ImGui docking (Capati/odin-imgui bindings) |
| Images | stb_image / stb_image_write |
| Audio | miniaudio (after MVP) |
| Video export | `ffmpeg` binary as a separate process (MVP) |
| Scripting | Lua 5.4 (after MVP) |
| Project file | JSON at first, then a zip container with assets |

## Architecture principles

- The core (document, evaluation, geometry) has no UI or platform dependencies,
  so it can be tested headless and shared with Android.
- Data-oriented document model; objects reference each other through handles (index + generation), not pointers.
- `evaluate(doc, time) -> posed scene` is a pure function:
  channels → bones → deformation → tessellation → render.
- Every animatable property is a `Channel(T)` of keyframes.
- Undo/redo uses mergeable commands.

## Phases

| Phase | Content | Estimate (1 dev full-time) |
|---|---|---|
| 0. Tests | SDL3 + SDL_GPU + ImGui; anti-aliased vector rendering; pen pressure; Android core build | 2–4 wk |
| 1. Foundations | math, document model, handles, undo, save/load, viewport, headless tests | 1–1.5 mo |
| 2. Vector drawing | point/curve model, drawing & editing tools (in progress: docs/phase2.md) | 1.5–2 mo |
| 3. Animation | channels, timeline UI, playback, onion skin | 1–1.5 mo |
| 4. Bones | bone layer, FK, point & weighted binding | 1–1.5 mo |
| 5. v0.1 MVP | PNG/MP4 export, autosave, polish | ~1 mo |
| 6. v0.2+ | graph editor, IK, switch layers, masks, audio/lip-sync, actions, Lua, SVG | ongoing |
| 7. Advanced | Smart Bones, Smart Warp, bitmap layers, vector brushes, effects, particles, physics, 3D camera, PSD | ongoing |
| 8. Android | touch UI on the shared core, gestures, packaging | after v0.2–0.3 |

## MVP (v0.1) scope

Goal: draw a simple character, rig it with bones, animate a walk cycle, export an MP4.

1. Canvas: pan/zoom/rotate, grid, document size & fps, background colour.
2. Vector layers: Bézier pen, freehand with pressure → curves, rectangle/ellipse;
   select/move/rotate/scale points, add/delete points, curvature/handles;
   solid fills, strokes with per-point width, shape order.
3. Layers: vector, group, image (PNG/JPG), bone; transform, opacity, visibility, lock, reorder.
4. Bones: hierarchy, FK posing, point binding + automatic distance weights, layer binding.
5. Animation: keys on layer transforms, points, bones, colour/opacity; step / linear / smooth.
6. Timeline: per-layer key rows, scrub, play at fps, loop range, key insert/delete/move/copy/paste, onion skin.
7. Workflow: unlimited undo/redo, save/open, autosave + recovery, shortcuts.
8. Export: PNG sequence (with transparency), MP4 via ffmpeg.
9. Platforms: Linux first, then Windows and macOS.

Out of MVP: graph editor, IK, Smart Bones, Smart Warp, switch layers, bitmap layers,
masks, effects, audio, actions, scripting, particles, physics, 3D, PSD/SVG, Android.
