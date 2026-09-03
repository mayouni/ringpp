# The widget-tree contract

*Drafted 2026-09-02 at Mansour's request, after the map type, before a
line of it existed — so that every later claim could be checked against
it, the way `VM-CONTRACT.md` is checked by `rpp/probe.ring` on every
load. The sections below are the contract as written; this block is
what has been built against it since.*

**Status, 2026-09-03.**

| gate | result |
|---|---|
| 7.1 eight lines | **7** — window + label + entry + button, scripted-keys line included; `examples/09-a-window-in-the-terminal` counts them from its own text and fails at nine |
| 7.2 two renderers, one model | **PASS** — the line renderer on Ring 1.27 and the keystroke renderer on Ring++, fed the same session, serialise to byte-identical model + events (`rnx-spike bench/tui72.py`, run by its gate) |
| 7.3 the Windows console | **measured and confirmed live** — see §7.3 |
| 7.4 no pixel | holds — the two renderers use flow layout and ANSI only |
| §9 Show() vs Table | **answered** — dependency-free renderer owns a minimal ASCII table; `Show()` is a Softanza-backed renderer's, a plug-in on the same tree |

Built: `rpp/tui.ring` (the tree; `Run`, line-driven, Ring 1.27 and Ring++;
`RunKeys`, keystroke-driven, Ring++ only, through the four builtins
`tui_init` `tui_key` `tui_size` `tui_done` in the binary). Three corrections
to the vocabulary below, all for one reason: a name a program is likely
to use itself is not one a library may take. The input widget is
**`Entry`**, not `Input`, and the list widget is **`Choice`**, not `List` —
`input` and `list` are Ring builtins, and a user function replaces a
builtin process-wide. The check box is **`Checkbox`**, not `Check` — three
of this repository's own tests define a `func Check` assertion helper,
and Ring refuses a second definition outright.

Built widgets: `Window` `Label` `Entry` `Button` `Checkbox` `Radio`
`Choice` `Table` `Menu` `Status`. Every list-like widget — table, radio,
choice, menu — navigates with the arrow keys under one rule, falling
through to the neighbouring widget at its edges, with a digit still
jumping straight to an item. The **§9 open question is now answered**: `Table` draws
a minimal ASCII table in `rpp/tui.ring`, because commitment #1 forbids the
library depending on Softanza — so `Show()` does *not* become the
terminal renderer's `Table`. `Show()` remains the rich artist, reached
through a Softanza-backed renderer, which is a different renderer on the
same tree. Not yet built: `Text`, `Row`, the callback form of `Run`
(§4), and the browser renderer. **`Text`'s two open questions are
settled** in §6.1–6.5, before any of it is written: the model shape is
fixed, the scrollport is renderer state, undo is the application's, Enter
means a line break, and §6.5 says which half of `Text` the parity gate
can honestly cover.

**RingPad's shell exists** (`examples/12-the-ringpad-shell`): a file list,
an editor placeholder, a menu and a status line, looping — choose a
command, the program acts, the next screen is drawn. It needs no callback:
`Run` returns when a menu item is activated, so the loop is the
application. What it does not have is the editing surface, and building
the shell first is what now names precisely what `Text` must do.

## 1. What it is, in one sentence

A **declarative widget tree** plus an **event contract**, rendered by
pluggable renderers, of which the **terminal renderer ships inside the one
Ring++ binary** and needs nothing else.

It is not a widget toolkit, not a layout engine beyond flow and grid, not a
binding to Qt, CopperSpice or libui, and not a replacement for Softanza's
own graphics engine. Those are renderers, or competitors, or both; this is
the thing they render.

## 2. Why — the numbers this rests on

| measured 2026-09-02 | |
|---|---|
| GUI/graphics bindings shipped with Ring 1.27 | **9** — ringqt, ringlibui, ringnappgui, ringraylib5, ringallegro, ringsdl, ringfreeglut, ringopengl, ringtilengine — with no shared model |
| smallest GUI application shipped with Ring (BMI Calculator) | **259 lines**; `setGeometry(0,10,290,60)`, `setStyleSheet` and `Qt_AlignHCenter` by line 20 |
| Softanza classes implementing `Show()` | **98**, plus ShowXT / ShowShort / ShowVertical and nine more variants — a renderer for an *implicit* description, the object |
| Python: window + entry + button, tkinter, standard library | **8 lines** (the comparison a newcomer makes; not run here — it opens a window) |

The batteries-included, learner-facing languages Ring's pitch invites
comparison with — Python, Tcl, Racket, Java, C#, Red — all ship a GUI.
Go, Rust and C do not, and nobody sells them as simple. Ring fails
precisely the comparison it invites.

## 3. The tree

A tree is a list of nodes. A node is a **kind**, a set of **properties**,
and **children**. Nothing else. It is a plain Ring value — a hash list —
so it can be built, inspected, serialised and diffed by ordinary code, and
so the map type is what makes it cheap.

```ring
$ui = Window("Sign in", [
    Label("Name"),
    Input(:name),
    Button("OK", :submit)
])
```

That is the line-count gate (§7): a window with an input and a button in
**at most eight lines**. If the first prototype needs nine, the contract is
wrong, not the prototype.

### 3.1 Node kinds, first tranche

| kind | properties | notes |
|---|---|---|
| `Window` | title, children | one per app at first; dialogs later |
| `Label` | text | |
| `Input` | name, value, placeholder | single line |
| `Text` | name, value | multi-line; **the one hard widget** — see §6 |
| `Button` | text, event | |
| `Check` | name, label, checked | |
| `Radio` | name, options, value | |
| `List` | name, items, selected | |
| `Table` | name, columns, rows, selected | `Show()` already renders one |
| `Menu` | items | |
| `Status` | text | |

Layout is **flow** (children in order, top to bottom) with an optional
`Row(...)` grouping. No absolute geometry. Ever. Pixels are a renderer's
business; a learner should never see `setGeometry`.

### 3.2 Properties are values

`Input(:name)` binds the widget to `$model[:name]`. A renderer reads the
model to draw and writes the model on input. The program never touches a
widget object; it touches its own map. This is what makes two renderers
comparable (§7): the model is the only state that matters, and it is a
plain value.

## 4. Events

An event is `[kind, name, value]`. Five kinds, no more in the first
tranche:

| kind | when | value |
|---|---|---|
| `:change` | an Input/Check/Radio/List/Table's value changed | the new value |
| `:submit` | a Button with `:submit`, or Enter in an Input | the model |
| `:click` | any Button | the button's name |
| `:key` | a key the widgets did not consume | the key |
| `:close` | the window is closing | nothing |

The program handles them in one place:

```ring
on = func(ev) {
    if ev[1] = :submit
        ? "hello " + $model[:name]
    ok
}
Run($ui, on)
```

`Run` blocks, drives the renderer, and returns on `:close`. There is no
`exec()`, no `app` object, no callbacks-as-strings.

## 5. The renderer interface

A renderer is anything that implements three functions:

```
mount(tree)                     -> handle    ; draw it
sync(handle, model)             -> nothing   ; model changed, redraw
poll(handle) -> event or NULL               ; next event, or nothing yet
```

That is the whole interface. A renderer does not know what the program
does; the program does not know what the renderer is.

### 5.1 Tiers, honestly

Under commitment #5 — one shipped binary, no toolchain — the tiers are:

| renderer | dependency | ships in the binary |
|---|---|---|
| **terminal** | none | **yes** — the reference renderer |
| **browser** | none: the binary serves the HTML and takes events over a local socket (Zig's std has networking) | **yes**, when built |
| native desktop windows | Qt, libui or CopperSpice underneath | no — a plug-in package |
| mobile | platform SDKs | no — horizon |

So the defensible sentence is: *terminal and browser from the one binary;
native desktop and mobile as pluggable renderers.* Not "desktop, web and
mobile from one tree". The first learner on a phone finds that gap.

**CopperSpice** is a Qt fork in Qt's size class. It changes the vendor,
not the problem this contract names — a dependency and a paradigm to
learn before the first window. If a native desktop renderer is wanted,
libui (already bound as ringlibui; small; native controls) is closer to
"simple". Either way it is a renderer decision made *after* the tree
exists, not part of the foundation.

## 6. The text widget, named as the hard one

`Text` — a multi-line editor with cursor, selection and undo — is the
component that would dominate a RingPad built on this. RingPad is the
right forcing application and the wrong first widget: build its **shell**
first (menus, file dialog, status bar, a plain `Text`) and treat the rich
editor as the one hard component it is. A RingPad that runs in the
terminal and in a browser from one tree is the demonstration that sells
the model.

The terminal renderer is also not only a learning aid. For the bank and
government domains this project names, an admin console over SSH with no
windowing system is a product.

### 6.1 What the model holds — fixed here, because the gate cannot check it

Gate 7.2 compares the model two renderers leave behind. It therefore
cannot catch the two of them meaning *different things by the same
model*: if one calls the cursor a byte offset and the other a
(row, column), the gate compares two encodings of two ideas and passes.
So the shape is fixed here, before either renderer is written.

A `Text` widget's model value is a **list of three**:

```ring
[ aLines, nRow, nCol ]        # m[:doc][1], m[:doc][2], m[:doc][3]
```

- `aLines` — the buffer as a **list of strings, one per line**, never a
  single string with newlines in it. This is the shape `str2list` already
  produces and `list2str` consumes (both measured on 1.27), it is what a
  cursor indexes directly, and it is what a renderer slices to draw a
  window. An empty buffer is `[ "" ]`, one empty line — never `[]`, so
  the cursor always has a line to be on.
- `nRow` — 1-based index into `aLines`.
- `nCol` — 1-based **character position before which the cursor sits**;
  `1` is before the first character and `len(line) + 1` is after the last.

**Serialised** (for the 7.2 comparison) as `nRow + "," + nCol + "," +`
the lines joined by a literal backslash-n, so a multi-line buffer stays
one line of transcript and the comparison stays a byte comparison.

### 6.2 The scrollport is the RENDERER's, never the model's

**Settled: a scroll offset is never model state.** The model holds the
cursor; each renderer scrolls however it must to keep the cursor visible,
and how much of the buffer it shows is its own business.

The reason is the gate itself. A scroll offset is a function of the
**viewport size**, and viewport size is exactly what differs between
renderers — a 30-line terminal, a browser window of any height, a phone.
Put the offset in the model and two renderers fed identical keystrokes
would be *required* to disagree; gate 7.2 would fail by construction, and
the failure would be correct.

That generalises into a rule worth stating once: **anything that depends
on the size of the viewport is renderer state.** It is the same principle
as §7.4's "no pixel ever reaches a program", one level up — a program
that cannot see pixels must not be able to see the window's height
either.

### 6.3 Undo belongs to the APPLICATION, in the model

**Settled: the widget does not implement undo.** History is history *of
the model*, and the program owns it: RingPad keeps a stack of previous
model values and a menu item — or a `:key` event for Ctrl-Z — restores
one. Undo is then a command like any other, it appears in the transcript,
and gate 7.2 checks it.

Undo inside the widget was the alternative and it fails two tests. It
would be **invisible to the gate**: undo state is not model state, so two
renderers could implement different undo semantics and never be caught.
And it sits badly with the event rule this project already measured its
way to — `:change` fires **per field, not per key** (that is what lets a
line renderer and a keystroke renderer agree at all), so a widget-level
undo would be operating on states the model never sees.

One concession, stated so it cannot be mistaken for a promise: a renderer
**may** offer a local undo *within* a field before the field is left,
because that is invisible to the model. It is a convenience, it is not
part of this contract, a renderer may lack it entirely, and it is bound
by one rule: leaving the field must yield exactly the value the same
keystrokes would yield in any other renderer.

The honest cost, named now rather than discovered later: undo granularity
at the application level is **per edit of a field**, not per keystroke,
because that is the only granularity both renderers can express. An
editor whose users expect per-keystroke undo needs the in-field
convenience above, and then the two renderers are no longer identical in
feel — only in outcome.

### 6.4 In `Text`, Enter means a line break

A necessary exception to "Enter leaves a field", and the only one: inside
a `Text`, **Enter inserts a line break** and **Tab leaves the field**. A
multi-line editor cannot spend its most-pressed key on navigation.

The line renderer expresses the same edit the only way a line-driven
interface can: it prompts for one line at a time and a **blank line ends
the field**. So `"abc"`, `"def"`, `""` on Ring 1.27 and `a b c Enter d e
f Tab` on Ring++ both leave `[ "abc", "def" ]` with the cursor after the
`f` — which is what makes `Text` gateable at all.

### 6.5 What gate 7.2 can and cannot check for `Text`

It checks **sessions both renderers can express**: typing, line breaks,
leaving a field. Those are compared byte for byte like every other tree.

It cannot check **keystroke-only sessions** — moving the cursor into the
middle of a line and typing there has no line-driven equivalent, and
pretending otherwise would be inventing an interaction to make a gate
green. Those are gated the other way instead: the same renderer, the same
keys, twice, byte-identical — the deterministic-replay check the examples
already run as `identical output : 1`.

Saying which half of `Text` the parity gate covers is not a weakening of
it. It is the difference between a gate that means something and a gate
that has been arranged to pass.

## 7. How it will be judged — fixed now, so it cannot be argued later

1. **Eight lines.** Window + input + button, in the tree of §3, in at most
   eight lines of Ring. Measured on the prototype, not asserted here.
2. **Two renderers, one model.** The same tree under the terminal renderer
   and the browser renderer, fed the same keystrokes, must leave
   **byte-identical model state**. This is the project's A/B discipline
   applied to GUI, and it is the gate: a renderer that agrees on the model
   is correct; one that does not is not, whatever it looks like.
3. **The Windows console.** Cursor positioning and raw input on Windows —
   console API versus VT sequences — is the known risk. It gets a probe
   and a number before anything is promised.
   *Measured 2026-09-03 (`bench/console_probe.py`): VT processing is OFF
   by default in conhost and ON in Windows Terminal; a process can switch
   it on itself in both; a raw key is readable in both without Enter.
   Confirmed live the same day: the keystroke renderer, through the four
   builtins, repainted cleanly in a plain `cmd.exe` window and in Windows
   Terminal. The binary fixes the console; the program never has to.*
4. **No pixel ever reaches a program.** If a learner's code contains a
   coordinate, the contract has been broken.

## 8. What stays outside

- Styling beyond a small theme (colours, bold). CSS is a renderer's
  language, not this one's.
- Absolute layout, drag-and-drop, canvases, animation.
- Anything that needs a native toolkit to express. Those are plug-in
  renderers, and they plug into this tree — they do not extend it.

## 9. Open questions, for Mansour

- **RPP-5a** — before or after the next Softanza-blocking item? The map
  type is done; the recommendation stands: write this contract (done),
  prototype the terminal renderer to get the eight-line number, then
  decide.
- Does Softanza's `Show()` become the terminal renderer's `Table`, or does
  the renderer own its own? The 98 classes suggest `Show()` is already
  the better artist; the contract only needs it to be *called* by the
  renderer, not rewritten.
