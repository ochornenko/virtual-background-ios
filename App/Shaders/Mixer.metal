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

/*
 Blends the camera frame with the background using Vision's person segmentation mask.
 The mask holds how much of each pixel is covered by a person, from 0 (background) to 1 (person),
 and is lower resolution than the frame, so it's sampled with linear filtering to keep edges soft.
 */
kernel void mixer(texture2d<float, access::sample> backgroundTexture [[ texture(0) ]],
                  texture2d<float, access::read> inputTexture [[ texture(1) ]],
                  texture2d<float, access::write> outputTexture [[ texture(2) ]],
                  texture2d<float, access::sample> maskTexture [[ texture(3) ]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    // Ensure the thread is within the bounds of the output texture
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) return;
    
    // Define a sampler for texture sampling
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    
    // Normalized position of the output pixel's center
    const float2 position = (float2(gid) + 0.5) / float2(outputTexture.get_width(), outputTexture.get_height());
    
    // Get how much of the current pixel is covered by a person
    const float coverage = maskTexture.sample(s, position).r;
    
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
