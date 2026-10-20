// The camera, for dart:ffi.
//
// libesca-camclient is C++; Dart wants a C ABI. This claims a camera and
// hands over each frame as tightly packed I420. Colour conversion is not done
// here: the application does it on the GPU, so the CPU only ever copies
// 1.5 bytes a pixel. Detections do not come through here -- they are a D-Bus
// signal, which Dart reads directly.

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

/// Bytes escv_next_i420 writes: width * height * 3 / 2.
int escv_i420_size(const escv_camera *camera);

/// Waits up to timeout_ms for the next frame and writes it to dst as I420
/// with no row padding: the Y plane (width x height), then U, then V (each
/// width/2 x height/2), whatever stride the camera delivers.
///
/// Returns 1 with *sequence set, 0 on timeout, -1 on an invalid argument.
int escv_next_i420(escv_camera *camera, uint8_t *dst, int timeout_ms, uint64_t *sequence);

#ifdef __cplusplus
}
#endif

#endif
