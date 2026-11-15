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
    
    private let backgroundTextureLock = NSLock()
    private var _backgroundTexture: MTLTexture?
    private var backgroundTexture: MTLTexture? {
        get { backgroundTextureLock.withLock { _backgroundTexture } }
        set { backgroundTextureLock.withLock { _backgroundTexture = newValue } }
    }
    private let segmentationWidth = 513
    private let segmentationHeight = 513
    private let segmentationMaskBuffer: MTLBuffer
    private let segmentationPixelBufferPool: CVPixelBufferPool
    private let outputPixelBufferPool: CVPixelBufferPool
    
    private let textureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState
    private let device: MTLDevice
    private let model: DeepLabV3?
    
    private let videoSize = CGSize(width: 720, height: 1280)
    
    private lazy var textureLoader: MTKTextureLoader = {
        return MTKTextureLoader(device: device)
    }()
    
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.minFilter = .linear
        return self.device.makeSamplerState(descriptor: samplerDescriptor)
    }()
    
    private static func loadDeepLabV3Model() -> DeepLabV3? {
        do {
            let config = MLModelConfiguration()
            return try DeepLabV3(configuration: config)
        } catch {
            Log.error("Error loading model: \(error)")
            return nil
        }
    }
    
    init?() {
        // Get the default metal device and create command queue.
        guard let metalDevice = MTLCreateSystemDefaultDevice(), let queue = metalDevice.makeCommandQueue() else {
            return nil
        }
        
        device = metalDevice
        commandQueue = queue
        model = Self.loadDeepLabV3Model()
        
        // Create the metal library containing the shaders.
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
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache) == kCVReturnSuccess,
              let cache = cache else {
            Log.error("Unable to allocate texture cache.")
            return nil
        }
        textureCache = cache
        
        guard let maskBuffer = metalDevice.makeBuffer(length: segmentationWidth * segmentationHeight * MemoryLayout<Int32>.stride,
                                                      options: .storageModeShared) else {
            Log.error("Failed to create segmentation mask buffer")
            return nil
        }
        segmentationMaskBuffer = maskBuffer
        
        guard let segmentationPool = makePixelBufferPool(width: segmentationWidth, height: segmentationHeight),
              let outputPool = makePixelBufferPool(width: Int(videoSize.width), height: Int(videoSize.height)) else {
            return nil
        }
        segmentationPixelBufferPool = segmentationPool
        outputPixelBufferPool = outputPool
    }
    
    func process(_ framePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let backgroundTexture = backgroundTexture else {
            return framePixelBuffer
        }
        
        guard let model = model,
              let segmentationInput = makePixelBuffer(from: segmentationPixelBufferPool),
              resizePixelBuffer(framePixelBuffer, into: segmentationInput),
              let output = try? model.prediction(image: segmentationInput) else {
            return nil
        }
        
        memcpy(segmentationMaskBuffer.contents(), output.semanticPredictions.dataPointer, segmentationMaskBuffer.length)
        
        guard let outputPixelBuffer = makePixelBuffer(from: outputPixelBufferPool),
              render(pixelBuffer: framePixelBuffer, backgroundTexture: backgroundTexture, into: outputPixelBuffer) else {
            return nil
        }
        
        return outputPixelBuffer
    }
    
    func applyBackgroundImage(_ image: CGImage) {
        if let resizedImage = resizeCGImageToFill(image, targetWidth: Int(videoSize.width), targetHeight: Int(videoSize.height)) {
            self.backgroundTexture = loadTexture(image: resizedImage)
        }
    }
    
    private func render(pixelBuffer: CVPixelBuffer, backgroundTexture: MTLTexture, into outputPixelBuffer: CVPixelBuffer) -> Bool {
        guard let inputCVTexture = makeMetalTexture(from: pixelBuffer, usage: .shaderRead),
              let inputTexture = CVMetalTextureGetTexture(inputCVTexture),
              let outputCVTexture = makeMetalTexture(from: outputPixelBuffer, usage: .shaderWrite),
              let outputTexture = CVMetalTextureGetTexture(outputCVTexture) else {
            return false
        }
        
        // Create a command buffer and compute command encoder.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        
        // Set the background texture for the compute shader.
        computeCommandEncoder.setTexture(backgroundTexture, index: 0)
        computeCommandEncoder.setTexture(inputTexture, index: 1)
        
        var params = MixParams()
        params.width = Int32(segmentationWidth)
        params.height = Int32(segmentationHeight)
        computeCommandEncoder.setBuffer(segmentationMaskBuffer, offset: 0, index: 0)
        computeCommandEncoder.setBytes(&params, length: MemoryLayout<MixParams>.size, index: 1)
        
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
        
        // The CVMetalTextures must stay alive until the GPU has finished with their MTLTextures
        withExtendedLifetime(inputCVTexture) {}
        withExtendedLifetime(outputCVTexture) {}
        
        guard commandBuffer.status == .completed else {
            Log.error("Mixer command buffer failed: \(String(describing: commandBuffer.error))")
            return false
        }
        return true
    }
    
    private func loadTexture(image: CGImage) -> MTLTexture? {
        do {
            // Load a texture from the specified image.
            return try textureLoader.newTexture(cgImage: image, options: [
                MTKTextureLoader.Option.SRGB : NSNumber(value: false)
            ])
        } catch {
            Log.error("Error: could not load texture \(error)")
            return nil
        }
    }
    
    /// Wraps the pixel buffer's memory in a Metal texture without copying it.
    private func makeMetalTexture(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, attributes, .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard let cvTexture = cvTextureOut else {
            Log.error("Video mixer failed to create texture")
            
            CVMetalTextureCacheFlush(textureCache, 0)
            return nil
        }
        
        return cvTexture
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
