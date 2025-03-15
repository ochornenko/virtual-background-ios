//
//  CameraVirtualBackgroundProcessor.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/23/25.
//

import CoreML
import MetalKit

protocol CameraProcessor {
    func process(_ framePixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
    func applyBackgroundImage(_ image: CGImage)
}

class CameraVirtualBackgroundProcessor: CameraProcessor {
    struct MixParams {
        var width: Int32 = 0
        var height: Int32 = 0
    }
    
    private var pixelData: [UInt8]
    private var backgroundTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var segmentationMaskBuffer: MTLBuffer?
    private var segmentationWidth = 513
    private var segmentationHeight = 513
    private var inputCameraTexture: MTLTexture?
    
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue
    private var computePipelineState: MTLComputePipelineState
    private var device: MTLDevice
    private lazy var model = getDeepLabV3Model()
    
    private let bytesPerPixel = 4
    private var videoSize = CGSize(width: 720, height: 1280)
    
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.minFilter = .linear
        return self.device.makeSamplerState(descriptor: samplerDescriptor)
    }()
    
    private func getDeepLabV3Model() -> DeepLabV3? {
        do {
            let config = MLModelConfiguration()
            return try DeepLabV3(configuration: config)
        } catch {
            Log.error("Error loading model: \(error)")
            return nil
        }
    }
    
    init?() {
        self.pixelData = [UInt8](repeating: 0, count: Int(videoSize.width * videoSize.height * 4))
        
        // Get the default metal device and create command queue.
        guard let metalDevice = MTLCreateSystemDefaultDevice(), let queue = metalDevice.makeCommandQueue() else {
            return nil
        }
        
        device = metalDevice
        commandQueue = queue
        
        // Create the metal library containing the shaders
        guard let library = metalDevice.makeDefaultLibrary() else {
            Log.error("Failed to make metal library")
            return nil
        }
        
        // Create a function with a specific name.
        guard let function = library.makeFunction(name: "mixer") else {
            Log.error("Metal function not found")
            return nil
        }
        
        // Create a compute pipeline with the above function.
        guard let cps = try? metalDevice.makeComputePipelineState(function: function) else {
            Log.error("Failed to compute pipeline")
            return nil
        }
        computePipelineState = cps
        
        // Initialize the cache to convert the pixel buffer into a Metal texture.
        var textCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textCache) != kCVReturnSuccess {
            Log.error("Unable to allocate texture cache.")
            return nil
        } else {
            textureCache = textCache!
        }
        
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.width = Int(videoSize.width)
        textureDescriptor.height = Int(videoSize.height)
        textureDescriptor.usage = [.shaderWrite, .shaderRead]
        
        outputTexture = self.device.makeTexture(descriptor: textureDescriptor)
        if outputTexture == nil {
            Log.error("Failed to create metal output texture")
            return nil
        }
    }
    
    func process(_ framePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard backgroundTexture != nil else {
            return framePixelBuffer
        }
        
        guard let resizedInput = resizePixelBuffer(framePixelBuffer, width: segmentationWidth, height: segmentationHeight),
              let output = try? model?.prediction(image: resizedInput) else {
            return nil
        }
        
        segmentationMaskBuffer = self.device.makeBuffer(length: segmentationHeight * segmentationWidth * MemoryLayout<Int32>.stride)
        
        if let buffer = self.segmentationMaskBuffer {
            memcpy(buffer.contents(), output.semanticPredictions.dataPointer, buffer.length)
        }
        
        guard let targetTexture = render(pixelBuffer: framePixelBuffer) else {
            return nil
        }
        
        var pixelBuffer: CVPixelBuffer?
        let bytesPerRow = bytesPerPixel * targetTexture.width
        let region = MTLRegionMake2D(0, 0, targetTexture.width, targetTexture.height)
        targetTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(videoSize.width),
                                         Int(videoSize.height),
                                         kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                         &pixelBuffer)
        
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBuffer else {
            Log.error("Failed to create pixel buffer \(status)")
            return nil
        }
        
        let flags = CVPixelBufferLockFlags(rawValue: 0)
        
        CVPixelBufferLockBaseAddress(pixelBuffer, flags)
        
        memcpy(CVPixelBufferGetBaseAddress(pixelBuffer), pixelData, Int(videoSize.height) * bytesPerRow)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, flags)
        
        return pixelBuffer
    }
    
    func applyBackgroundImage(_ image: CGImage) {
        if let resizedImage = resizeCGImageToFill(image, targetWidth: Int(videoSize.width), targetHeight: Int(videoSize.height)) {
            self.backgroundTexture = loadTexture(image: resizedImage)
        }
    }
    
    private func render(pixelBuffer: CVPixelBuffer?) -> MTLTexture? {
        // Create a command buffer and compute command encoder.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        if let backgroundTexture = backgroundTexture {
            // Set the background texture for the compute shader
            computeCommandEncoder.setTexture(backgroundTexture, index: 0)
        }
        
        if let pixelBuffer = pixelBuffer, let inputTexture = makeTextureFromCVPixelBuffer(pixelBuffer: pixelBuffer) {
            inputCameraTexture = inputTexture
            computeCommandEncoder.setTexture(inputTexture, index: 1)
        }
        
        if let maskBuffer = segmentationMaskBuffer {
            var params = MixParams()
            params.width = Int32(segmentationWidth)
            params.height = Int32(segmentationHeight)
            computeCommandEncoder.setBuffer(maskBuffer, offset: 0, index: 0)
            computeCommandEncoder.setBytes(&params, length: MemoryLayout<MixParams>.size, index: 1)
        }
        
        computeCommandEncoder.setTexture(outputTexture, index: 2)
        
        computeCommandEncoder.setSamplerState(samplerState, index: 0)
        computeCommandEncoder.setSamplerState(samplerState, index: 1)
        computeCommandEncoder.setSamplerState(samplerState, index: 2)
        
        // Set the compute pipeline state for the command encoder.
        computeCommandEncoder.dispatch(pipeline: computePipelineState, width: Int(videoSize.width), height: Int(videoSize.height))
        
        // End the encoding of the command.
        computeCommandEncoder.endEncoding()
        
        // Commit the command buffer for execution.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return outputTexture
    }
    
    private func makeTextureFromCVPixelBuffer(pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create a Metal texture from the image buffer
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache!, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            Log.error("Video mixer failed to create texture")
            
            CVMetalTextureCacheFlush(textureCache!, 0)
            return nil
        }
        
        return texture
    }
}

extension MTLComputeCommandEncoder {
    /**
     Dispatches a compute kernel on a 2-dimensional grid.
     
     - Parameters:
     - pipeline: the object with the compute function
     - width: the first dimension
     - height: the second dimension
     */
    public func dispatch(pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = pipeline.maxTotalThreadsPerThreadgroup / w
        
        let threadGroupSize = MTLSizeMake(w, h, 1)
        let threadGroups = MTLSizeMake(
            (width  + threadGroupSize.width  - 1) / threadGroupSize.width,
            (height + threadGroupSize.height - 1) / threadGroupSize.height, 1)
        
        setComputePipelineState(pipeline)
        dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
    }
}
