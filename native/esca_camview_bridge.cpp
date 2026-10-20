#include "esca_camview_bridge.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

#include "esca/camera/client.hpp"

struct escv_camera {
    esca::camera::CameraClient client;
    esca::camera::FrameFormat format;
    std::vector<uint8_t> frame;

    // Source column and row for every output pixel, rebuilt only when the
    // output size or rotation changes. Keeps the per-pixel loop free of
    // divisions, which is most of what it would otherwise cost.
    int map_w = 0, map_h = 0, map_rotation = -1;
    std::vector<int> map_x;  // per output column
    std::vector<int> map_y;  // per output row
};

namespace {

void copy_error(char *dst, int len, const std::string &message)
{
    if (dst && len > 0)
        std::snprintf(dst, static_cast<size_t>(len), "%s", message.c_str());
}

inline uint8_t clamp_byte(int v) { return static_cast<uint8_t>(std::clamp(v, 0, 255)); }

/// For 0 and 180 the output column picks the source column; for 90 and 270
/// it picks the source row, and the output row picks the column.
void build_maps(escv_camera *c, int out_w, int out_h, int rotation)
{
    const int w = static_cast<int>(c->format.width);
    const int h = static_cast<int>(c->format.height);
    const bool sideways = rotation == 90 || rotation == 270;
    const int rot_w = sideways ? h : w;
    const int rot_h = sideways ? w : h;

    c->map_x.resize(static_cast<size_t>(out_w));
    c->map_y.resize(static_cast<size_t>(out_h));
    for (int x = 0; x < out_w; ++x)
        c->map_x[static_cast<size_t>(x)] = static_cast<int>(static_cast<int64_t>(x) * rot_w / out_w);
    for (int y = 0; y < out_h; ++y)
        c->map_y[static_cast<size_t>(y)] = static_cast<int>(static_cast<int64_t>(y) * rot_h / out_h);

    c->map_w = out_w;
    c->map_h = out_h;
    c->map_rotation = rotation;
}

} // namespace

extern "C" {

escv_camera *escv_open(char *error, int error_len)
{
    auto *c = new escv_camera;
    const auto ids = c->client.device_list();
    if (ids.empty()) {
        copy_error(error, error_len, "no cameras (is esca-camerad running?)");
        delete c;
        return nullptr;
    }

    std::string reason;
    if (c->client.open(ids.front(), reason) < 0 || !c->client.start(reason)) {
        copy_error(error, error_len, reason);
        c->client.close();
        delete c;
        return nullptr;
    }
    c->format = c->client.frame_format();
    return c;
}

void escv_close(escv_camera *camera)
{
    if (!camera)
        return;
    camera->client.stop();
    camera->client.close();
    delete camera;
}

int escv_width(const escv_camera *camera) { return camera ? static_cast<int>(camera->format.width) : 0; }

int escv_height(const escv_camera *camera) { return camera ? static_cast<int>(camera->format.height) : 0; }

int escv_next_rgba(escv_camera *c, uint8_t *dst, int out_w, int out_h, int rotation,
                   int timeout_ms, uint64_t *sequence)
{
    if (!c || !dst || out_w <= 0 || out_h <= 0)
        return -1;
    if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270)
        return -1;

    esca::camera::FrameInfo info;
    if (!c->client.next_frame(c->frame, info, timeout_ms))
        return 0;

    if (out_w != c->map_w || out_h != c->map_h || rotation != c->map_rotation)
        build_maps(c, out_w, out_h, rotation);

    const int width = static_cast<int>(c->format.width);
    const int height = static_cast<int>(c->format.height);
    const int stride = static_cast<int>(c->format.stride);
    const int chroma_stride = stride / 2;

    // I420: a full Y plane, then quarter-size U and V planes.
    const uint8_t *y_plane = c->frame.data();
    const uint8_t *u_plane = y_plane + static_cast<size_t>(stride) * height;
    const uint8_t *v_plane = u_plane + static_cast<size_t>(chroma_stride) * (height / 2);

    for (int dy = 0; dy < out_h; ++dy) {
        uint8_t *out = dst + static_cast<size_t>(dy) * out_w * 4;
        const int ry = c->map_y[static_cast<size_t>(dy)];

        for (int dx = 0; dx < out_w; ++dx) {
            const int rx = c->map_x[static_cast<size_t>(dx)];

            int sx = rx;
            int sy = ry;
            switch (rotation) {
            case 90:  sx = ry;              sy = height - 1 - rx; break;
            case 180: sx = width - 1 - rx;  sy = height - 1 - ry; break;
            case 270: sx = width - 1 - ry;  sy = rx;              break;
            default: break;
            }

            const int y = y_plane[static_cast<size_t>(sy) * stride + sx];
            const size_t chroma = static_cast<size_t>(sy / 2) * chroma_stride + sx / 2;
            const int u = u_plane[chroma] - 128;
            const int v = v_plane[chroma] - 128;

            // BT.601, the conversion libcamera's YUV420 output follows.
            out[0] = clamp_byte(y + ((91881 * v) >> 16));
            out[1] = clamp_byte(y - ((22554 * u + 46802 * v) >> 16));
            out[2] = clamp_byte(y + ((116130 * u) >> 16));
            out[3] = 255;
            out += 4;
        }
    }

    if (sequence)
        *sequence = info.sequence;
    return 1;
}

} // extern "C"
