// Copyright 2025 Oleg Chornenko.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <metal_stdlib>
using namespace metal;

struct MixParams {
    int segmentationWidth;
    int segmentationHeight;
};

// DeepLabV3 (PASCAL VOC) class label for "person"
constant int PERSON_CLASS = 15;

/*
 Returns 1 if the mask cell at the specified coordinate contains the class "person", 0 otherwise.
 Coordinates outside the mask are clamped to the nearest edge cell.
 */
static inline float person_at(int x, int y, int width, int height, device const int* mask) {
    x = clamp(x, 0, width - 1);
    y = clamp(y, 0, height - 1);
    return mask[y * width + x] == PERSON_CLASS ? 1.0 : 0.0;
}

/*
 Returns how much of the specified position is covered by a person, from 0 to 1.
 Blends the four nearest mask cells so the edge of the person is soft instead of blocky.
 The position should be normalized between 0 and 1.
 */
static inline float person_coverage(float2 pos, int width, int height, device const int* mask) {
    // Mask cell centers sit at half-cell offsets
    const float2 cell = pos * float2(width, height) - 0.5;
    const float2 cellFloor = floor(cell);
    const float2 weight = cell - cellFloor;
    const int x = int(cellFloor.x);
    const int y = int(cellFloor.y);
    
    const float top = mix(person_at(x, y, width, height, mask),
                          person_at(x + 1, y, width, height, mask), weight.x);
    const float bottom = mix(person_at(x, y + 1, width, height, mask),
                             person_at(x + 1, y + 1, width, height, mask), weight.x);
    return mix(top, bottom, weight.y);
}

kernel void mixer(texture2d<float, access::sample> backgroundTexture [[ texture(0) ]],
                  texture2d<float, access::read> inputTexture [[ texture(1) ]],
                  texture2d<float, access::write> outputTexture [[ texture(2) ]],
                  device const int* segmentationMask [[buffer(0)]],
                  constant MixParams& params [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    // Ensure the thread is within the bounds of the output texture
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;
    
    // Define a sampler for texture sampling
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    
    // Normalized position of the output pixel's center
    const float2 position = (float2(gid) + 0.5) / float2(outputTexture.get_width(), outputTexture.get_height());
    
    // Get how much of the current pixel is covered by a person
    const float coverage = person_coverage(position, params.segmentationWidth, params.segmentationHeight, segmentationMask);
    
    // Read the input pixel
    const float4 inPixel = inputTexture.read(gid);
    float4 outPixel = inPixel;
    
    if (coverage < 1.0) {
        // Blend the background in where the pixel is not fully covered by a person
        const float4 backgroundPixel = backgroundTexture.sample(s, position);
        outPixel = mix(backgroundPixel, inPixel, coverage);
    }
    
    // Write the output pixel
    outputTexture.write(outPixel, gid);
}
