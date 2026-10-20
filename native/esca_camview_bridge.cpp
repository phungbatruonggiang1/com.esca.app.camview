#include "esca_camview_bridge.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "esca/camera/client.hpp"

struct escv_camera {
    esca::camera::CameraClient client;
    esca::camera::FrameFormat format;
    std::vector<uint8_t> frame;
};

namespace {

void copy_error(char *dst, int len, const std::string &message)
{
    if (dst && len > 0)
        std::snprintf(dst, static_cast<size_t>(len), "%s", message.c_str());
}

/// Copies rows of a plane, dropping the padding past each row's width.
uint8_t *copy_plane(uint8_t *dst, const uint8_t *src, int width, int height, int stride)
{
    if (stride == width) {
        std::memcpy(dst, src, static_cast<size_t>(width) * height);
        return dst + static_cast<size_t>(width) * height;
    }
    for (int y = 0; y < height; ++y) {
        std::memcpy(dst, src + static_cast<size_t>(y) * stride, static_cast<size_t>(width));
        dst += width;
    }
    return dst;
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

int escv_i420_size(const escv_camera *camera)
{
    return camera ? static_cast<int>(camera->format.width * camera->format.height * 3 / 2) : 0;
}

int escv_next_i420(escv_camera *c, uint8_t *dst, int timeout_ms, uint64_t *sequence)
{
    if (!c || !dst)
        return -1;

    esca::camera::FrameInfo info;
    if (!c->client.next_frame(c->frame, info, timeout_ms))
        return 0;

    const int width = static_cast<int>(c->format.width);
    const int height = static_cast<int>(c->format.height);
    const int stride = static_cast<int>(c->format.stride);

    // The camera's I420: a full Y plane at `stride`, then quarter-size U and V
    // planes at stride / 2, as libesca-ui read them.
    const uint8_t *y = c->frame.data();
    const uint8_t *u = y + static_cast<size_t>(stride) * height;
    const uint8_t *v = u + static_cast<size_t>(stride / 2) * (height / 2);

    uint8_t *out = copy_plane(dst, y, width, height, stride);
    out = copy_plane(out, u, width / 2, height / 2, stride / 2);
    copy_plane(out, v, width / 2, height / 2, stride / 2);

    if (sequence)
        *sequence = info.sequence;
    return 1;
}

} // extern "C"
