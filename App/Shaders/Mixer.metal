//
//  Mixer.metal
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/25/25.
//

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
    const int x = int(pos.x * width);
    const int y = int(pos.y * height);
    return mask[y * width + x];
}

/*
 Returns the probability that the specified pixel coordinate contains the
 class "person". The position should be normalized between 0 and 1.
 */
static float get_person_probability(float2 pos, int width, int height, device int* mask) {
    return get_class(pos, width, height, mask) == 15;
}

kernel void mixer(texture2d<float, access::sample> backgroundTexture [[ texture(0) ]],
                  texture2d<float, access::read> inputTexture [[ texture(1) ]],
                  texture2d<float, access::write> outputTexture [[ texture(2) ]],
                  device int* segmentationMask [[buffer(0)]],
                  constant MixParams& params [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    
    constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
    
    const float2 pos = float2(float(gid.x) / float(outputTexture.get_width()),
                              float(gid.y) / float(outputTexture.get_height()));
    const float is_person = get_person_probability(pos, params.segmentationWidth, params.segmentationHeight, segmentationMask);
    
    const float4 inPixel = inputTexture.read(gid);
    float4 outPixel = inPixel;
    
    if (is_person < 0.5f) {
        // Use a sampler so that the background texture doesn't have to be the same size as the input texture.
        outPixel = backgroundTexture.sample(s, float2(float(gid.x) / float(inputTexture.get_width()),
                                                      float(gid.y) / float(inputTexture.get_height())));
    }
    
    outputTexture.write(outPixel, gid);
}
