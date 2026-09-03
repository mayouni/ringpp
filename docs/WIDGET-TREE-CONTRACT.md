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

Built: `rpp/tui.ring` (the tree; `Run`, line-driven, Ring 1.27 and Ring++;
`RunKeys`, keystroke-driven, Ring++ only, through the four builtins
`tui_init` `tui_key` `tui_size` `tui_done` in the binary). Three corrections
to the vocabulary below, all for one reason: a name a program is likely
to use itself is not one a library may take. The input widget is
**`Entry`**, not `Input`, and the list widget is **`Choice`**, not `List` —
`input` and `list` are Ring builtins, and a user function replaces a
builtin process-wide. The check box is **`Checkbox`**, not `Check` — three
of this repository's own tests define a `func Check` assertion helper,
and Ring refuses a second definition outright. Not yet built: `Text`,
`Check`, `Radio`, `List`, `Table`, `Menu`, `Status`, `Row`, the callback
form of `Run` (§4), and the browser renderer.

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
