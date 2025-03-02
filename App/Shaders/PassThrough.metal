//
//  PassThrough.metal
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/24/25.
//

#include <metal_stdlib>
using namespace metal;

// Vertex input/output structure for passing results from vertex shader to fragment shader
struct VertexIO {
    float4 position [[position]];
    float2 textureCoord [[user(texturecoord)]];
};

// Vertex shader for a textured quad
vertex VertexIO vertexPassThrough(const device packed_float4 *pPosition [[ buffer(0) ]],
                                  const device packed_float2 *pTexCoords [[ buffer(1) ]],
                                  uint vid [[ vertex_id ]]) {
    VertexIO outVertex;
    
    // Assign position and texture coordinates from the input buffers
    outVertex.position = pPosition[vid];
    outVertex.textureCoord = pTexCoords[vid];
    
    return outVertex;
}

// Fragment shader for a textured quad
fragment half4 fragmentPassThrough(VertexIO inputFragment [[ stage_in ]],
                                   texture2d<half> inputTexture [[ texture(0) ]],
                                   sampler samplr [[ sampler(0) ]]) {
    // Sample the texture at the given texture coordinates
    return inputTexture.sample(samplr, inputFragment.textureCoord);
}
