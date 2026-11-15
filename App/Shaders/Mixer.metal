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

// Mask values within this distance of 0 or 1 are treated as solid background or person and are not refined
constant float EDGE_THRESHOLD = 0.02;

// Size of the neighbourhood, in output pixels, used to refine the edge (7x7 samples, 12 pixels across)
constant int REFINE_RADIUS = 6;
constant int REFINE_STEP = 2;

// How quickly a neighbour's influence falls off with distance, in output pixels
constant float SPATIAL_SIGMA = 4.0;

// How quickly a neighbour's influence falls off with color difference, in normalized RGB
constant float COLOR_SIGMA = 0.1;

// The refined coverage is remapped through this range to tighten the edge
constant float EDGE_LOW = 0.25;
constant float EDGE_HIGH = 0.75;

/*
 Refines the person coverage at an edge pixel using the camera image as a guide (joint bilateral filtering).
 Neighbours with a color similar to the center pixel contribute more, so the edge snaps to
 where the color actually changes in the camera image instead of following the coarse mask.
 */
static inline float refine_coverage(int2 center,
                                    float3 centerColor,
                                    float2 size,
                                    texture2d<float, access::read> inputTexture,
                                    texture2d<float, access::sample> maskTexture,
                                    sampler s) {
    const int2 maxCoord = int2(size) - 1;
    float weightedCoverage = 0.0;
    float totalWeight = 0.0;
    
    for (int dy = -REFINE_RADIUS; dy <= REFINE_RADIUS; dy += REFINE_STEP) {
        for (int dx = -REFINE_RADIUS; dx <= REFINE_RADIUS; dx += REFINE_STEP) {
            const int2 coord = clamp(center + int2(dx, dy), int2(0), maxCoord);
            const float3 colorDifference = inputTexture.read(uint2(coord)).rgb - centerColor;
            
            const float spatial = float(dx * dx + dy * dy) / (2.0 * SPATIAL_SIGMA * SPATIAL_SIGMA);
            const float range = dot(colorDifference, colorDifference) / (2.0 * COLOR_SIGMA * COLOR_SIGMA);
            const float weight = exp(-(spatial + range));
            
            weightedCoverage += weight * maskTexture.sample(s, (float2(coord) + 0.5) / size).r;
            totalWeight += weight;
        }
    }
    
    // The center sample always has weight 1, so totalWeight is never 0
    return smoothstep(EDGE_LOW, EDGE_HIGH, weightedCoverage / totalWeight);
}

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
    const float2 size = float2(outputTexture.get_width(), outputTexture.get_height());
    const float2 position = (float2(gid) + 0.5) / size;
    
    // Read the input pixel
    const float4 inPixel = inputTexture.read(gid);
    
    // Get how much of the current pixel is covered by a person, refining it only along the edge
    float coverage = maskTexture.sample(s, position).r;
    if (coverage > EDGE_THRESHOLD && coverage < 1.0 - EDGE_THRESHOLD) {
        coverage = refine_coverage(int2(gid), inPixel.rgb, size, inputTexture, maskTexture, s);
    }
    
    float4 outPixel = inPixel;
    
    if (coverage < 1.0) {
        // Blend the background in where the pixel is not fully covered by a person
        const float4 backgroundPixel = backgroundTexture.sample(s, position);
        outPixel = mix(backgroundPixel, inPixel, coverage);
    }
    
    // Write the output pixel
    outputTexture.write(outPixel, gid);
}
