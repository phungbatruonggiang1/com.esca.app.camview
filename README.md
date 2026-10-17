# ESCA Camera Viewer

Shows the camera full screen and draws the vision service's detections over
it. A Wayland client, about a thousand lines, no toolkit.

    camera (IMX219) → esca-camerad → shared memory ─┬→ esca-visiond ──┐
                                                     │                │ Detections
                                                     └→ esca-camview ←┘

Two sources, deliberately independent. Frames arrive from shared memory at
30 fps and go straight to the screen. Boxes arrive over D-Bus at about 10 fps,
whenever the detector finishes. **If the vision service is not running, or
dies, the video keeps playing without boxes** — which is the whole reason
detection lives in another process.

## Running it

Through the application manager, which is how it is meant to start:

    esca-appctl launch vn.sparc.esca.camview

By hand, as the user that owns the Wayland session:

    XDG_RUNTIME_DIR=/run WAYLAND_DISPLAY=wayland-0 esca-camview

Options: `--rotate 0|90|180|270` (default 270, see below), `--every N` frames
per inference, `--threshold F`, `--no-detect` for video only, `--no-status`.

## Decisions worth knowing about

**wl_shm, not EGL.** The frame is already in system memory when the camera
service hands it over. Converting YUV420 to XRGB costs a few milliseconds of
CPU — about 30% of one core at 1920×1080 — and wl_shm passes the result
straight to the compositor. EGL would buy nothing at this size and would cost
a dependency on the whole Mesa stack.

**Boxes lag the picture, and that is allowed.** A detection describes a frame
from roughly 70 ms ago. Rather than hold frames back to match, the viewer
draws the newest boxes over the newest frame and lets them trail slightly.
Nothing moves fast enough in front of this camera for it to matter. Boxes
more than fifteen frames stale are dropped entirely, so a service that stops
leaves no ghosts behind.

**A 5×7 bitmap font, embedded.** Labels have to be legible over video. The
alternative — freetype and a font file, or cairo and pango — is megabytes of
dependency to draw the word "person".

**Both buffers busy means skip the frame.** There are two shm buffers. When
the compositor holds both, the viewer drops that frame instead of waiting:
by the time one frees up, a newer frame has arrived and the old one is of no
further use.

**`--rotate 270` by default** because the sensor on this board is mounted
sideways. The cost is black bars down both sides of a landscape screen — a
720×1280 portrait image on a 1920×1080 display uses about a third of it.
Mounting the camera the right way up and passing `--rotate 0` is the real
fix; the option is here because the hardware is how it is.

## Layout

    src/main.cpp      the loop: frame in, boxes over it, commit
    src/window.cpp    Wayland: registry, xdg-shell, two shm buffers
    src/render.cpp    YUV420 to XRGB with rotation and letterboxing, boxes, text
    src/font5x7.hpp   the font
    data/appinfo.json what esca-appmanager reads to launch this

`window.cpp` dispatches Wayland without blocking, using the
prepare_read/read_events/cancel_read sequence. `wl_display_dispatch_pending`
on its own is not enough — it drains the queue but never reads the socket, so
`wl_buffer.release` never arrives, both buffers stay busy, and the picture
freezes on the first frame while the process sits at 4% CPU looking healthy.

## Building

In the Yocto build it is the `esca-camview` recipe in `meta-sparc-esca`. It
needs `wayland`, `wayland-native` (for `wayland-scanner`, which turns the
xdg-shell XML into C at build time), `wayland-protocols`, and the client
libraries of the camera and vision services.
