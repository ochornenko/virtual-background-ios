//
//  CameraPreview.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/22/25.
//

import MetalKit

class CameraPreview: MTKView {
    
    enum Rotation: Int {
        case rotate0Degrees, rotate90Degrees, rotate180Degrees, rotate270Degrees
    }
    
    var mirroring = false
    var rotation: Rotation = .rotate0Degrees
    var pixelBuffer: CVPixelBuffer?
    
    private let syncQueue = DispatchQueue(label: "Preview.SyncQueue", attributes: .concurrent)
    
    private var textureCache: CVMetalTextureCache?
    private var textureWidth = 0
    private var textureHeight = 0
    private var textureMirroring = false
    private var textureRotation: Rotation = .rotate0Degrees
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
    
    private lazy var sampler: MTLSamplerState? = {
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
        super.init(frame: frame, device: device)
        
        self.device = MTLCreateSystemDefaultDevice()
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
        let (pixelBuffer, mirroring, rotation) = syncQueue.sync {
            (self.pixelBuffer, self.mirroring, self.rotation)
        }
        
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
        
        if texture.width != textureWidth || texture.height != textureHeight ||
            bounds != internalBounds || mirroring != textureMirroring || rotation != textureRotation {
            setupTransform(width: texture.width, height: texture.height, mirroring: mirroring, rotation: rotation)
        }
        
        guard let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor),
              let renderPipelineState = renderPipelineState,
              let sampler = sampler else {
            return
        }
        
        commandEncoder.label = "Preview display"
        commandEncoder.setRenderPipelineState(renderPipelineState)
        commandEncoder.setVertexBuffer(vertexCoordBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(textCoordBuffer, offset: 0, index: 1)
        commandEncoder.setFragmentTexture(texture, index: 0)
        commandEncoder.setFragmentSamplerState(sampler, index: 0)
        commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        commandEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func setupTransform(width: Int, height: Int, mirroring: Bool, rotation: Rotation) {
        internalBounds = self.bounds
        textureWidth = width
        textureHeight = height
        textureMirroring = mirroring
        textureRotation = rotation
        
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        
        switch rotation {
        case .rotate0Degrees, .rotate180Degrees:
            scaleX = Float(internalBounds.width / CGFloat(textureWidth))
            scaleY = Float(internalBounds.height / CGFloat(textureHeight))
        case .rotate90Degrees, .rotate270Degrees:
            scaleX = Float(internalBounds.width / CGFloat(textureHeight))
            scaleY = Float(internalBounds.height / CGFloat(textureWidth))
        }
        
        if scaleX > scaleY {
            scaleY = scaleX / scaleY
            scaleX = 1.0
        } else {
            scaleX = scaleY / scaleX
            scaleY = 1.0
        }
        
        if mirroring { scaleX *= -1.0 }
        
        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
             scaleX, -scaleY, 0.0, 1.0,
             -scaleX, scaleY, 0.0, 1.0,
             scaleX, scaleY, 0.0, 1.0
        ]
        vertexCoordBuffer = device?.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.size)
        
        let textureCoordinates: [Float] = {
            switch rotation {
            case .rotate0Degrees:   return [0, 1, 1, 1, 0, 0, 1, 0]
            case .rotate180Degrees: return [1, 0, 0, 0, 1, 1, 0, 1]
            case .rotate90Degrees:  return [1, 1, 1, 0, 0, 1, 0, 0]
            case .rotate270Degrees: return [0, 0, 0, 1, 1, 0, 1, 1]
            }
        }()
        textCoordBuffer = device?.makeBuffer(bytes: textureCoordinates, length: textureCoordinates.count * MemoryLayout<Float>.size)
    }
    
    private func flushTextureCache() {
        textureCache.map { CVMetalTextureCacheFlush($0, 0) }
    }
}
