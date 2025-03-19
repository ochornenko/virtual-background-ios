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

/*
 Returns the predicted class label at the specified pixel coordinate.
 The position should be normalized between 0 and 1.
 */
static inline int get_class(float2 pos, int width, int height, device int* mask) {
    const int x = clamp(int(pos.x * width), 0, width - 1);
    const int y = clamp(int(pos.y * height), 0, height - 1);
    return mask[y * width + x];
}

/*
 Returns true if the specified pixel coordinate contains the class "person".
 */
static inline bool is_person_at(float2 position, int width, int height, device int* mask) {
    return get_class(position, width, height, mask) == 15;
}

kernel void mixer(texture2d<float, access::sample> backgroundTexture [[ texture(0) ]],
                  texture2d<float, access::read> inputTexture [[ texture(1) ]],
                  texture2d<float, access::write> outputTexture [[ texture(2) ]],
                  device int* segmentationMask [[buffer(0)]],
                  constant MixParams& params [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    // Ensure the thread is within the bounds of the output texture
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;
    
    // Define a sampler for texture sampling
    constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
    
    // Use output resolution for normalized position
    const float2 position = float2(float(gid.x) / float(outputTexture.get_width()),
                                   float(gid.y) / float(outputTexture.get_height()));
    
    // Get the probability that the current pixel contains a person
    const float is_person = is_person_at(position, params.segmentationWidth, params.segmentationHeight, segmentationMask);
    
    // Read the input pixel
    const float4 inPixel = inputTexture.read(gid);
    float4 outPixel = inPixel;
    
    if (!is_person) {
        // If the pixel does not contain a person, use the background texture
        outPixel = backgroundTexture.sample(s, position);
    }
    
    // Write the output pixel
    outputTexture.write(outPixel, gid);
}
