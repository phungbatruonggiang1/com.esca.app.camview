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
that `dart:ffi` can call. It claims the camera, waits for a frame and
converts YUV420 to RGBA (BT.601, the same arithmetic `libesca-ui` used) at
the size the screen shows it, with lookup tables so the per-pixel loop does
no division. Built by the `esca-camview-bridge` recipe.

**`lib/`** is the Flutter application. The bridge blocks, so it runs on its
own isolate; the UI isolate only receives finished RGBA buffers. The isolate
holds at most two frames ahead of the screen: when drawing falls behind,
conversion stops instead of spending a core on frames that would be thrown
away. Detections are a D-Bus signal, read directly in Dart.

## Decisions worth knowing about

**Boxes lag the picture, and that is allowed.** A detection describes a frame
from roughly 70 ms ago. The newest boxes are drawn over the newest frame and
trail it slightly; holding frames back to match would halve the frame rate.
Boxes more than fifteen frames stale are dropped, so a service that stops
leaves no ghosts behind.

**Never more than 1280 pixels across are converted.** The GPU scales the
image to the screen for nothing; every pixel converted on the CPU costs.

**The camera is released before exiting.** Leaving through **Trang chủ**
stops the detector and closes the camera, so neither service keeps a client
that is gone.

**Rotation is configuration.** A sensor mounted sideways is set with
`ESCA_CAMVIEW_ROTATE` (90, 180 or 270) in `data/appinfo.json`'s `env`. It
costs about 2.2× per converted pixel; fixing the mount is cheaper.

## Layout

    native/                    libesca-camview-bridge (C++, CMake)
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
