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

import MetalKit

class CameraPreview: MTKView {
    
    var pixelBuffer: CVPixelBuffer? {
        get {
            return syncQueue.sync { _pixelBuffer }
        }
        set {
            syncQueue.async(flags: .barrier) {
                self._pixelBuffer = newValue
            }
        }
    }
    
    private var _pixelBuffer: CVPixelBuffer?
    
    private let syncQueue = DispatchQueue(label: "preview.sync.queue", attributes: .concurrent)
    
    private var textureCache: CVMetalTextureCache?
    private var textureWidth = 0
    private var textureHeight = 0
    private var internalBounds: CGRect!
    
    private lazy var commandQueue: MTLCommandQueue? = {
        return device?.makeCommandQueue()
    }()
    
    private lazy var renderPipelineState: MTLRenderPipelineState? = {
        guard let device = device, let defaultLibrary = device.makeDefaultLibrary() else { return nil }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.vertexFunction = defaultLibrary.makeFunction(name: "vertexPassThrough")
        pipelineDescriptor.fragmentFunction = defaultLibrary.makeFunction(name: "fragmentPassThrough")
        
        return try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }()
    
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        return device?.makeSamplerState(descriptor: samplerDescriptor)
    }()
    
    private var vertexCoordBuffer: MTLBuffer?
    private var textCoordBuffer: MTLBuffer?
    
    override init(frame: CGRect, device: MTLDevice? = nil) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        
        colorPixelFormat = .bgra8Unorm
        createTextureCache()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func createTextureCache() {
        guard let device = device else { return }
        var newTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &newTextureCache) == kCVReturnSuccess {
            textureCache = newTextureCache
        } else {
            assertionFailure("Unable to allocate texture cache")
        }
    }
    
    override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable,
              let currentRenderPassDescriptor = currentRenderPassDescriptor,
              let previewPixelBuffer = pixelBuffer,
              let textureCache = textureCache else {
            return
        }
        
        let width = CVPixelBufferGetWidth(previewPixelBuffer)
        let height = CVPixelBufferGetHeight(previewPixelBuffer)
        
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               previewPixelBuffer,
                                                               nil,
                                                               .bgra8Unorm,
                                                               width,
                                                               height,
                                                               0,
                                                               &cvTextureOut)
        
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            Log.error("Failed to create preview texture \(status)")
            
            flushTextureCache()
            return
        }
        
        if texture.width != textureWidth || texture.height != textureHeight || bounds != internalBounds {
            setupTransform(width: texture.width, height: texture.height)
        }
        
        guard let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor),
              let renderPipelineState = renderPipelineState,
              let samplerState = samplerState else {
            return
        }
        
        commandEncoder.label = "Preview"
        commandEncoder.setRenderPipelineState(renderPipelineState)
        commandEncoder.setVertexBuffer(vertexCoordBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(textCoordBuffer, offset: 0, index: 1)
        commandEncoder.setFragmentTexture(texture, index: 0)
        commandEncoder.setFragmentSamplerState(samplerState, index: 0)
        commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        commandEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    /// Scales the quad so the texture fills the view while keeping its aspect ratio, cropping whatever overflows.
    private func setupTransform(width: Int, height: Int) {
        internalBounds = self.bounds
        textureWidth = width
        textureHeight = height
        
        var scaleX = Float(internalBounds.width / CGFloat(textureWidth))
        var scaleY = Float(internalBounds.height / CGFloat(textureHeight))
        
        if scaleX > scaleY {
            scaleY = scaleX / scaleY
            scaleX = 1.0
        } else {
            scaleX = scaleY / scaleX
            scaleY = 1.0
        }
        
        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
             scaleX, -scaleY, 0.0, 1.0,
             -scaleX, scaleY, 0.0, 1.0,
             scaleX, scaleY, 0.0, 1.0
        ]
        vertexCoordBuffer = device?.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.size)
        
        let textureCoordinates: [Float] = [0, 1, 1, 1, 0, 0, 1, 0]
        textCoordBuffer = device?.makeBuffer(bytes: textureCoordinates, length: textureCoordinates.count * MemoryLayout<Float>.size)
    }
    
    private func flushTextureCache() {
        textureCache.map { CVMetalTextureCacheFlush($0, 0) }
    }
}
