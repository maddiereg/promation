# Phase 2: vector drawing

## Tools

| Tool | Key | What it does |
|---|---|---|
| Select | V | Click / Shift+click / box-select shapes; drag to move (Shift: one axis). Transform box: drag a grip to scale (Shift: keep proportions, Alt: from centre), the top circle to rotate (Shift: 15° steps). |
| Points | A | Select points (click, Shift+click, box). Drag to move; drag a handle to bend (Alt breaks a smooth point into a cusp). Double-click a curve to add a point, a point to switch corner/smooth (also C). With two or more points selected, the transform box scales and rotates them. |
| Draw | B | Freehand with pressure. The dense input is fitted to a few Bézier knots (Schneider's algorithm, width included in the error); "Fit curves" can be turned off. |
| Pen | P | Click for corners, click-drag for smooth points. Click the first point to close, Enter or double-click the last point to finish open. Backspace / Ctrl+Z remove the last point, Esc cancels. |
| Rectangle | R | Drag. Shift: square. Alt: from centre. |
| Ellipse | E | Drag. Shift: circle. Alt: from centre. |
| Pan | H | Drag. Middle drag and Space+drag pan in every tool. |
| Eraser | pen's eraser end | Deletes the shapes it touches on the active layer; one eraser stroke is one undo step. |

Other keys: Del/Backspace delete the selection, Ctrl+A selects all, Esc clears
the selection, PgUp/PgDn raise/lower (with Shift: front/back), G shows the
grid, Shift+G snaps to it.

## Style panel

Fill on/off and colour, stroke on/off and colour, width. With nothing selected
it sets the style of new shapes. With shapes selected it shows the first one's
style and edits apply to all of them; a slider drag is one undo step. Width
scales a stroke's widths proportionally so pressure variation survives; in the
Points tool it sets the width of the selected points (per-point width).

## Core changes

- `core/curves.odin`: flattening with curve parameters, hit testing (non-zero
  fill, stroke width), nearest point on a path, de Casteljau split, curve
  bounds, rectangle/ellipse knots, corner/smooth conversion, curve fitting.
- `core/history.odin`: `set_path` (knots + style, merges during drags),
  `move_path` (restacking), and history groups (`history_begin_group` /
  `history_end_group`) so an edit touching several paths is one undo step.
  Groups ended with the same merge key merge, which is how a drag of several
  shapes stays one step.
- The project file format is unchanged.

## Not done yet

- Point selection is per layer; editing across layers needs switching layers.
- Moving shapes between layers.
- Holes (several contours per shape) and the even-odd rule.
- Group opacity is still approximate (Phase 1 note).
