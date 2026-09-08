# Brief for a canvas that becomes Compose code

Hand this to whoever draws the screens — a designer in Claude Design, or Claude Design itself
from a product brief. Each line carries its reason; keep the constraint even when you shorten
the wording. The result is a canvas `design-to-compose` can turn into reference PNGs without a
person exporting anything, and a screen the code can be measured against.

## The brief

> **Screens for `<product>`, `<feature>`.** Draw them in the app's existing design system
> (`<link or path to theme / tokens / component sheet>`), as **static artboards**, one artboard
> per screen state, on a canvas page per screen.
>
> 1. **One artboard per state, named `<Screen>_<State>`**: `Checkout_Empty`, `Checkout_Data`,
>    `Checkout_Error`, `Checkout_Loading`, `Checkout_DeleteDialog`. Letters, digits and
>    underscores only. The states are the ones in the screen document: `<list them>`. A dark
>    variant is `<Screen>_<State>_Dark`.
> 2. **Fixed size, the target's**: `390×844` for the phone screens, `<w>×<h>` for `<other>`. Set
>    the artboard frame (`canvas.json` `w`/`h`) and the root element to the same size; the root
>    fills the frame with the screen's background.
> 3. **Static**: plain markup with inline styles. No `{{ holes }}`, no `<sc-for>` / `<sc-if>`,
>    no `<dc-import>`, no tweaks. Repeated items (list rows) are written out, with the sample
>    data below.
> 4. **The app's font**: `<family>` via a Google Fonts `<link>` in the artboard head (or the
>    embedded face the app ships). Not `system-ui`, not the browser default.
> 5. **Exact values from the design system**: colours, type sizes and weights, line heights,
>    radii, spacing and control heights as they are in `<tokens>`; a value that is not in the
>    system is called out in a note on the canvas, not invented silently.
> 6. **Sample data**, the same on every artboard that shows it: `<the fixture data — names,
>    amounts, dates>`. Dates fixed to `<date>`.
> 7. **No device chrome**: no status bar, no keyboard, no browser frame inside the artboard.
> 8. **One canvas page per screen**, artboards in a row in state order, notes beside them for
>    anything the code has to know that the picture does not say (what a tap does, what
>    scrolls).

## Why each line

1. **Naming** — viddik names a screenshot `<group>_<name>.png` and the parity task looks the
   reference up by exactly that file; the artboard's name is the file's name. A space or a
   slash becomes `_` on the way, so the underscore form is the one that survives unchanged.
2. **Size** — the comparison is pixel for pixel at the artboard's size; a reference of another
   size is reported and never scored. Setting the root to the frame size keeps the export and
   the render identical; a root larger than the frame is clipped, smaller shows the frame's
   background.
3. **Static** — the canvas editor resolves template logic with its own runtime; the renderer
   that produces the references is a plain browser and shows the braces. A static artboard is
   also what a designer edits in place, so nothing is lost.
4. **Font** — two rasterizers drawing different families differ on every line of text and the
   number means nothing; drawing the same family they differ on the anti-aliased edges only,
   which the tolerance is set for. Google Fonts is the one external host the canvas loads from.
5. **Tokens** — the code maps every value to the theme; a value with no token either extends the
   system on purpose or is drift, and the note is what tells the two apart.
6. **Sample data** — the fixture that renders the Compose side uses fixed data; if the design
   shows different names or a different date, the diff is red where nothing is wrong.
7. **No chrome** — the app draws none of it, so it would be a guaranteed mismatch band at the
   top of every screen.
8. **Pages and notes** — one page per screen keeps `--only "Checkout*"` meaningful and the
   canvas navigable; notes are the only place behaviour lives in a static design.

## What comes back

For each artboard: a reference PNG committed next to the goldens, a Compose fixture of the same
name and size, and a parity number in the pull request. A number above the tolerance comes
with a reason (text residual, a token the theme lacks, a state the design and the document
disagree on), never with a loosened threshold.
