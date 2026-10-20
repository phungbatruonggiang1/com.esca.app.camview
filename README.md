# ESCA Camera AI

The camera live, with what the detector found drawn over it.

    camera (IMX219) → esca-camerad → shared memory ─┬→ esca-visiond ──┐
                                                     │                │ Detections
                                                     └→ esca-camview ←┘

Two sources, deliberately independent. Frames arrive from shared memory at
30 fps and go straight to the screen. Boxes arrive over D-Bus at about 7 a
second, whenever the detector finishes. **If the vision service is not
running, or dies, the video keeps playing without boxes** — which is the
whole reason detection lives in another process.

## Two halves

**`native/`** is `libesca-camview-bridge`: `libesca-camclient` behind a C ABI
that `dart:ffi` can call. It claims the camera, waits for a frame and copies
it out as tightly packed I420. It converts nothing. Built by the
`esca-camview-bridge` recipe.

**`lib/`** is the Flutter application. The bridge blocks, so it runs on its
own isolate, writing into native buffers both isolates can see; only the
buffer's index crosses between them. The isolate holds at most two frames
ahead of the screen: when drawing falls behind, it waits instead of filling
buffers nobody will draw. Detections are a D-Bus signal, read directly in
Dart.

**`shaders/i420.frag`** turns the frame into colour on the GPU. The I420
bytes are uploaded unchanged as an RGBA texture a quarter of the capture
width wide, four bytes to a texel; the shader reads the right byte of each
plane and applies BT.601, and rotates while it is at it.

## Why the GPU converts

Converting YUV420 to RGBA on the CPU, then handing four bytes a pixel to the
engine and on to the GPU, cost 1.7 cores on the Pi 4 and held the picture at
18 fps -- and starved the detector beside it, whose inference time rose from
about 70 ms to over 300. Uploading the I420 as it is moves 1.5 bytes a
pixel, and the conversion becomes a few instructions per fragment on a GPU
that was otherwise idle. `test/i420_shader_test.dart` holds the shader to
libesca-ui's integer conversion, within rounding, at every rotation.

## Decisions worth knowing about

**Boxes lag the picture, and that is allowed.** A detection describes a frame
from roughly 70 ms ago. The newest boxes are drawn over the newest frame and
trail it slightly; holding frames back to match would halve the frame rate.
Boxes more than fifteen frames stale are dropped, so a service that stops
leaves no ghosts behind.

**The camera is released before exiting.** Leaving through **Trang chủ**
stops the detector and closes the camera, so neither service keeps a client
that is gone.

**Rotation is configuration.** A sensor mounted sideways is set with
`ESCA_CAMVIEW_ROTATE` (90, 180 or 270) in `data/appinfo.json`'s `env`. The
shader does the rotating, so it costs nothing measurable.

## Layout

    native/                    libesca-camview-bridge (C++, CMake)
    shaders/i420.frag          I420 to RGB, on the GPU
    lib/camera_feed.dart       the bridge over dart:ffi, on its own isolate
    lib/vision.dart            esca-visiond over D-Bus
    lib/camview_controller.dart  what the screen shows, and when boxes are stale
    lib/camview_screen.dart    the picture, the boxes, the side panel
    lib/kit/                   the shared ESCA look
    data/appinfo.json          what esca-appmanager reads to launch this

Launch: `esca-appctl launch vn.sparc.esca.camview`, or press its tile in
ESCA Home.

## Building and testing on the development host

    flutter pub get
    flutter analyze
    flutter test

The tests drive the screen against a fake service, so they need neither the
board nor the bus. `pubspec.lock` is committed: the Yocto build resolves the
same package versions the tests ran against.

On the board the bundle is built by its recipe in `meta-sparc-esca`
(`esca-flutter-app.inc`), run by `ivi-homescreen` inside the Weston session,
and started by `esca-appmanagerd` through the launcher in `/usr/bin`.

`lib/kit/` is the shared ESCA look, copied identically into every
application. Change one copy, copy it to the others.
