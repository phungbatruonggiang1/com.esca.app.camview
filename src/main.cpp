// esca-camview: the camera on screen, with what the detector found drawn
// over it.
//
// Two sources, deliberately independent. Frames come from the camera
// service's shared memory at 30 fps; boxes come from the vision service over
// D-Bus at about 10. If the vision service is not running, or dies, the video
// keeps playing without boxes -- which is the whole reason detection lives in
// another process.

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <string>
#include <vector>

#include "esca/camera/client.hpp"
#include "esca/vision/client.hpp"

#include "render.hpp"
#include "window.hpp"

using namespace esca::camview;

namespace {

volatile std::sig_atomic_t g_quit = 0;

void handle_signal(int) { g_quit = 1; }

struct Options {
    int rotation = 270;   ///< the sensor is mounted sideways on this board
    uint32_t every = 3;   ///< ask the service to detect on every Nth frame
    double threshold = 0.5;
    bool detect = true;
    bool status = true;
};

int usage()
{
    std::fprintf(stderr,
                 "usage: esca-camview [options]\n"
                 "  --rotate DEG      0, 90, 180 or 270 clockwise (default 270)\n"
                 "  --every N         detect on every Nth frame (default 3)\n"
                 "  --threshold F     minimum score to draw (default 0.5)\n"
                 "  --no-detect       video only, do not talk to the vision service\n"
                 "  --no-status       hide the status line\n");
    return 2;
}

/// Boxes older than this are not drawn. The detector is always a frame or
/// two behind -- that is expected -- but if the service stops, leaving its
/// last boxes on screen would be a lie about what the camera is seeing.
constexpr uint64_t kMaxStaleFrames = 15;

void draw_detections(uint32_t *pixels, int w, int h, int stride, const Viewport &view,
                     const esca::vision::DetectionSet &set, double threshold)
{
    constexpr int kScale = 3;
    constexpr int kThickness = 3;

    for (const esca::vision::Detection &d : set.objects) {
        if (d.score < threshold)
            continue;

        const Rect box = map_box(view, d.left, d.top, d.right, d.bottom);
        if (box.w <= 0 || box.h <= 0)
            continue;

        const uint32_t colour = colour_for_class(d.class_id);
        stroke_rect(pixels, w, h, stride, box, colour, kThickness);

        char score[8];
        std::snprintf(score, sizeof(score), " %.2f", d.score);
        const std::string label = d.label + score;

        // The caption sits above the box, or inside it when the box is
        // already at the top of the screen.
        const int tw = text_width(label, kScale);
        const int th = text_height(kScale);
        int ly = box.y - th - 6;
        if (ly < view.area.y)
            ly = box.y + kThickness + 2;

        fill_rect(pixels, w, h, stride, { box.x, ly - 3, tw + 8, th + 6 }, 0xff000000);
        draw_text(pixels, w, h, stride, box.x + 4, ly, label, colour, kScale);
    }
}

} // namespace

int main(int argc, char **argv)
{
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };

        if (arg == "--rotate") {
            opt.rotation = std::stoi(next());
            if (opt.rotation != 0 && opt.rotation != 90 && opt.rotation != 180
                && opt.rotation != 270)
                return usage();
        }
        else if (arg == "--every") opt.every = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--threshold") opt.threshold = std::stod(next());
        else if (arg == "--no-detect") opt.detect = false;
        else if (arg == "--no-status") opt.status = false;
        else return usage();
    }

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    // --- camera -------------------------------------------------------------
    esca::camera::CameraClient camera;
    const auto ids = camera.device_list();
    if (ids.empty()) {
        std::fprintf(stderr, "esca-camview: no cameras (is esca-camerad running?)\n");
        return 1;
    }

    std::string error;
    if (camera.open(ids.front(), error) < 0) {
        std::fprintf(stderr, "esca-camview: open: %s\n", error.c_str());
        return 1;
    }
    if (!camera.start(error)) {
        std::fprintf(stderr, "esca-camview: start: %s\n", error.c_str());
        return 1;
    }
    const esca::camera::FrameFormat format = camera.frame_format();
    std::fprintf(stderr, "esca-camview: camera %s, %ux%u stride %u, rotated %d\n",
                 ids.front().c_str(), format.width, format.height, format.stride, opt.rotation);

    // --- detections ----------------------------------------------------------
    esca::vision::VisionClient vision;
    bool detecting = false;
    if (opt.detect) {
        // Not fatal. Video without boxes is a far better failure than a black
        // screen, and the service may come up later.
        if (!vision.connect(error)) {
            std::fprintf(stderr, "esca-camview: no vision service (%s); video only\n",
                         error.c_str());
        } else if (!vision.start(error)) {
            std::fprintf(stderr, "esca-camview: vision start: %s; video only\n", error.c_str());
        } else {
            vision.set_every(opt.every, error);
            vision.set_threshold(opt.threshold, error);
            detecting = true;
        }
    }

    // --- window --------------------------------------------------------------
    Window window;
    if (!window.open("ESCA camera", "vn.sparc.esca.camview", error)) {
        std::fprintf(stderr, "esca-camview: %s\n", error.c_str());
        return 1;
    }

    // --- loop ----------------------------------------------------------------
    std::vector<uint8_t> frame;
    esca::camera::FrameInfo info;

    auto fps_since = std::chrono::steady_clock::now();
    int fps_frames = 0;
    double fps = 0.0;

    while (!g_quit && !window.closed()) {
        if (!window.dispatch()) {
            std::fprintf(stderr, "esca-camview: compositor went away\n");
            break;
        }

        if (!camera.next_frame(frame, info, 1000))
            continue;

        int w = 0;
        int h = 0;
        int stride = 0;
        uint32_t *pixels = window.acquire(w, h, stride);
        if (!pixels) {
            // Both buffers are still on the compositor's side. Skipping is
            // right: by the time one frees up this frame would be stale.
            continue;
        }

        const Viewport view = blit_yuv420(frame.data(), static_cast<int>(format.width),
                                          static_cast<int>(format.height),
                                          static_cast<int>(format.stride), opt.rotation, pixels,
                                          w, h, stride);

        esca::vision::DetectionSet set;
        if (detecting) {
            set = vision.latest();
            // The detector runs behind by design; only drop boxes that have
            // fallen far enough behind to be describing a different scene.
            const bool fresh =
                set.frame_seq != 0 && info.sequence <= set.frame_seq + kMaxStaleFrames;
            if (fresh)
                draw_detections(pixels, w, h, stride, view, set, opt.threshold);
            else
                set = {};
        }

        ++fps_frames;
        const auto now = std::chrono::steady_clock::now();
        const double elapsed = std::chrono::duration<double>(now - fps_since).count();
        if (elapsed >= 1.0) {
            fps = fps_frames / elapsed;
            fps_frames = 0;
            fps_since = now;
        }

        if (opt.status) {
            char line[160];
            std::snprintf(line, sizeof(line), "%.0f fps | %.0f ms | %zu objects | seq %llu",
                          fps, set.inference_ms, set.objects.size(),
                          static_cast<unsigned long long>(info.sequence));
            const int scale = 3;
            const int th = text_height(scale);
            fill_rect(pixels, w, h, stride,
                      { 0, h - th - 16, text_width(line, scale) + 24, th + 16 }, 0xff000000);
            draw_text(pixels, w, h, stride, 12, h - th - 8, line, 0xffffffff, scale);
        }

        window.present();
    }

    if (detecting)
        vision.stop();
    window.close();
    camera.stop();
    camera.close();
    std::fprintf(stderr, "esca-camview: done\n");
    return 0;
}
