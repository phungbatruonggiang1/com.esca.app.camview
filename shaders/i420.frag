// I420 to RGB on the GPU.
//
// libesca-camview-bridge hands over the frame as packed I420 -- Y, then U,
// then V, no row padding -- and Dart uploads those bytes unchanged as an RGBA
// texture uFrame.x / 4 texels wide and uFrame.y * 1.5 rows tall, four bytes
// to a texel. This reads the right byte for each plane and converts, so the
// CPU never touches a pixel and the upload is 1.5 bytes a pixel, not 4.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;        // the area drawn into, in logical pixels
uniform vec2 uFrame;       // capture width and height, in pixels
uniform float uRotation;   // quarter turns clockwise: 0, 1, 2 or 3
uniform sampler2D uPlanes;

out vec4 fragColor;

// One byte of the packed frame, by its column within a uFrame.x-byte row.
float byteAt(float column, float row) {
    vec2 texels = vec2(uFrame.x / 4.0, uFrame.y * 1.5);
    float texel = floor(column / 4.0);
    vec4 t = texture(uPlanes, (vec2(texel, row) + 0.5) / texels);
    float lane = column - texel * 4.0;
    return lane < 0.5 ? t.r : lane < 1.5 ? t.g : lane < 2.5 ? t.b : t.a;
}

void main() {
    vec2 p = FlutterFragCoord().xy / uSize;

    // Back from the rotated picture to the sensor's own orientation, the same
    // mapping libesca-ui used.
    vec2 s = p;
    if (uRotation > 2.5) {
        s = vec2(1.0 - p.y, p.x);
    } else if (uRotation > 1.5) {
        s = vec2(1.0 - p.x, 1.0 - p.y);
    } else if (uRotation > 0.5) {
        s = vec2(p.y, 1.0 - p.x);
    }
    vec2 pixel = min(floor(s * uFrame), uFrame - 1.0);

    float luma = byteAt(pixel.x, pixel.y);

    // A chroma sample covers 2x2 pixels. The U plane starts at row uFrame.y
    // and is uFrame.x * uFrame.y / 4 bytes long; V follows it.
    float chroma = floor(pixel.y / 2.0) * (uFrame.x / 2.0) + floor(pixel.x / 2.0);
    float row = uFrame.y + floor(chroma / uFrame.x);
    float column = mod(chroma, uFrame.x);
    float u = byteAt(column, row) - 0.5;
    float v = byteAt(column, row + uFrame.y / 4.0) - 0.5;

    // BT.601, the conversion libcamera's YUV420 output follows.
    vec3 rgb = vec3(luma + 1.402 * v,
                    luma - 0.344136 * u - 0.714136 * v,
                    luma + 1.772 * u);
    fragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
