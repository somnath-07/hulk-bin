# HulkBin

A pixel-art Hulk stands on your Dock's Trash tile. Drop a file in and he smashes it.

He's drawn as a 16-bit sprite: full standing figure, slab arms with a bright rim light down each
outer edge, square jaw under a heavy brow, clenched teeth, shaggy mane, torn denim shorts. His legs
and shorts cover the bin behind him, so you see the Hulk rather than the Trash can.

## Build and run

Requires macOS and the Swift toolchain that ships with Xcode or the Command Line Tools. No
dependencies, no package manager — one Swift file.

```bash
./build.sh && open HulkBin.app
```

First launch: macOS will ask for **Accessibility** access (System Settings → Privacy & Security → Accessibility). That is how the app locates the Trash tile in your Dock. Grant it, then relaunch.

There's no Dock icon of its own — look for the small green head in the menu bar. That menu has **Smash test** and **Combo ×3** so you can watch the animation without deleting anything.

## How it works

macOS gives no way to replace the Trash icon itself, so instead:

- The Accessibility API finds the Trash tile's position in the Dock (`AXTrashDockItem`).
- A transparent, **click-through** window is parked over that tile and the Hulk is drawn into it. Your drops land on the real Trash underneath — the app never moves or deletes a file.
- Global mouse events plus the drag pasteboard tell it files are heading for the bin. The smash only fires once the dragged files have actually left their old location, so a cancelled drag doesn't trigger it.

The art is drawn procedurally — no image assets. Shapes are rasterised into a 132×118 pixel buffer
with a six-tone shading pass (outline, deep core shadow, mid shadow, base, rim light, bright outer
edge), then scaled with nearest-neighbour to match your Dock's tile size. He stands about twice the
tile's height, so he looms over the Dock rather than sitting inside it.

## The animation

Hover a dragged file near the bin and he winds up: fists rise, brows drop, eyes light green. Then:

1. **Wind-up** — both fists overhead, with a quiver at the top
2. **Slam** — fists drive down, body drops, the file squashes flat under them
3. **Impact** — the file bursts into pixel debris made from its own icon, plus dust, sparks, confetti and a shockwave ring; a "SMASH!" comic title pops up and the whole scene shakes
4. **Chest pound** — four beats, each shaking the screen again
5. **Settle** — back to idle breathing, with the occasional bicep flex

Drop several files and he smashes them one after another, cycling SMASH! / CRUSH! / BOOM! / HULK!

A synthesised bass thump plays on each impact (toggle in the menu).

## Menu options

- **Smash test** / **Combo ×3** — preview without deleting anything
- **Hulk sound** — on by default
- **Bigger / Smaller / Reset size** — 10% a step, remembered between launches
- **Nudge Hulk up / down** — if he sits slightly high or low over your Dock
- **⌘⌫ detection** — off unless you grant Full Disk Access. With it, deleting in Finder via ⌘⌫ (not just dragging) also triggers a smash, by watching `~/.Trash`. Optional.

## Rebuild

```bash
./build.sh
```

Render the contact sheet of key frames:

```bash
./HulkBin.app/Contents/MacOS/HulkBin --preview preview.png
```

## Sizing and Dock magnification

His scale comes from the Dock's **configured** tile size (`com.apple.dock tilesize`), never the live
tile width reported by the Accessibility API. That matters because with Dock magnification on, the
tile balloons as your cursor approaches and anything scaled from it would balloon too. Pinning to
the configured size keeps him exactly the same size whether or not the Dock is zoomed.

He still *follows* the tile's position, so he stays put over the Trash as the Dock reflows.

## After every rebuild: re-grant Accessibility

`build.sh` ad-hoc signs the app (`codesign -s -`), which produces a **different signature on every
build**. macOS ties the Accessibility grant to that signature, so a rebuilt HulkBin is a different
app as far as TCC is concerned — the old grant no longer applies, and because an entry already
exists macOS will not prompt you again. The app launches, finds no Dock tile, and hides its window.
It looks exactly like it failed to launch.

The app now shows an alert when this happens. To clear it:

```bash
tccutil reset Accessibility dev.afti.hulkbin
```

then relaunch and accept the prompt. Equivalently, delete the HulkBin row under System Settings →
Privacy & Security → Accessibility with the **−** button before relaunching — toggling the checkbox
off and on is not enough, the stale row has to go.

You don't need to relaunch after granting: the app re-checks trust a few times a second and will
appear on its own.

## Caveats
- He covers the Trash tile, so you lose the full/empty state at a glance. Right-click still works — the window is click-through.
- The app is ad-hoc signed. If macOS complains, right-click → Open the first time.
