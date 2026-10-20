// The camera, for dart:ffi.
//
// libesca-camclient is C++ and hands over YUV420; Flutter wants a C ABI and
// RGBA. This is the whole of the translation: claim a camera, wait for a
// frame, convert it at the size the screen will show it. Detections do not
// come through here -- they are a D-Bus signal, which Dart reads directly.

#ifndef ESCA_CAMVIEW_BRIDGE_H
#define ESCA_CAMVIEW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct escv_camera escv_camera;

/// Claims the first camera esca-camerad offers and starts it. Returns NULL
/// on failure, with the reason written to error.
escv_camera *escv_open(char *error, int error_len);

/// Stops this client's stream and releases the camera.
void escv_close(escv_camera *camera);

/// Capture size, valid once open.
int escv_width(const escv_camera *camera);
int escv_height(const escv_camera *camera);

/// Waits up to timeout_ms for the next frame and writes it to dst as RGBA,
/// out_w by out_h, rotated clockwise by rotation (0, 90, 180 or 270). The
/// caller picks out_w and out_h with the rotated aspect ratio; the image is
/// scaled to fill them exactly.
///
/// Returns 1 with *sequence set, 0 on timeout, -1 on an invalid argument.
int escv_next_rgba(escv_camera *camera, uint8_t *dst, int out_w, int out_h, int rotation,
                   int timeout_ms, uint64_t *sequence);

#ifdef __cplusplus
}
#endif

#endif
