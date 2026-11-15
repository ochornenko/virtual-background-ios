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
import Vision

protocol CameraProcessor {
    func process(_ framePixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
    func applyBackgroundImage(_ image: CGImage)
}

class CameraVirtualBackgroundProcessor: CameraProcessor {
    private let backgroundTextureLock = NSLock()
    private var _backgroundTexture: MTLTexture?
    private var backgroundTexture: MTLTexture? {
        get { backgroundTextureLock.withLock { _backgroundTexture } }
        set { backgroundTextureLock.withLock { _backgroundTexture = newValue } }
    }
    private let outputPixelBufferPool: CVPixelBufferPool
    
    private let textureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState
    private let device: MTLDevice
    
    private let segmentationRequest = makeSegmentationRequest()
    
    // Keeps state between frames, which gives Vision a more temporally stable mask than one-off requests
    private let sequenceRequestHandler = VNSequenceRequestHandler()
    
    private let videoSize = CGSize(width: 720, height: 1280)
    
    private lazy var textureLoader: MTKTextureLoader = {
        return MTKTextureLoader(device: device)
    }()
    
    init?() {
        // Get the default metal device and create command queue.
        guard let metalDevice = MTLCreateSystemDefaultDevice(), let queue = metalDevice.makeCommandQueue() else {
            return nil
        }
        
        device = metalDevice
        commandQueue = queue
        
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
        
        guard let outputPool = makePixelBufferPool(width: Int(videoSize.width), height: Int(videoSize.height)) else {
            return nil
        }
        outputPixelBufferPool = outputPool
        
        warmUpSegmentation()
    }
    
    func process(_ framePixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let backgroundTexture = backgroundTexture else {
            return framePixelBuffer
        }
        
        do {
            try sequenceRequestHandler.perform([segmentationRequest], on: framePixelBuffer, orientation: .up)
        } catch {
            Log.error("Person segmentation failed: \(error)")
            return nil
        }
        
        guard let maskPixelBuffer = segmentationRequest.results?.first?.pixelBuffer,
              let outputPixelBuffer = makePixelBuffer(from: outputPixelBufferPool),
              render(pixelBuffer: framePixelBuffer, maskPixelBuffer: maskPixelBuffer,
                     backgroundTexture: backgroundTexture, into: outputPixelBuffer) else {
            return nil
        }
        
        return outputPixelBuffer
    }
    
    func applyBackgroundImage(_ image: CGImage) {
        if let resizedImage = resizeCGImageToFill(image, targetWidth: Int(videoSize.width), targetHeight: Int(videoSize.height)) {
            self.backgroundTexture = loadTexture(image: resizedImage)
        }
    }
    
    private static func makeSegmentationRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        // `.accurate` is meant for still images and is too slow for live video
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }
    
    /// Runs segmentation once on a blank frame in the background so Vision loads its model before the first real frame.
    /// Uses its own request because `segmentationRequest` belongs to the camera's data output queue.
    private func warmUpSegmentation() {
        guard let pixelBuffer = makePixelBuffer(from: outputPixelBufferPool) else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([Self.makeSegmentationRequest()])
            } catch {
                Log.error("Person segmentation warm-up failed: \(error)")
            }
        }
    }
    
    private func render(pixelBuffer: CVPixelBuffer,
                        maskPixelBuffer: CVPixelBuffer,
                        backgroundTexture: MTLTexture,
                        into outputPixelBuffer: CVPixelBuffer) -> Bool {
        guard let inputCVTexture = makeMetalTexture(from: pixelBuffer, pixelFormat: .bgra8Unorm, usage: .shaderRead),
              let inputTexture = CVMetalTextureGetTexture(inputCVTexture),
              let maskCVTexture = makeMetalTexture(from: maskPixelBuffer, pixelFormat: .r8Unorm, usage: .shaderRead),
              let maskTexture = CVMetalTextureGetTexture(maskCVTexture),
              let outputCVTexture = makeMetalTexture(from: outputPixelBuffer, pixelFormat: .bgra8Unorm, usage: .shaderWrite),
              let outputTexture = CVMetalTextureGetTexture(outputCVTexture) else {
            return false
        }
        
        // Create a command buffer and compute command encoder.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        
        computeCommandEncoder.setTexture(backgroundTexture, index: 0)
        computeCommandEncoder.setTexture(inputTexture, index: 1)
        computeCommandEncoder.setTexture(outputTexture, index: 2)
        computeCommandEncoder.setTexture(maskTexture, index: 3)
        
        // Set the compute pipeline state for the command encoder.
        computeCommandEncoder.dispatch(pipeline: computePipelineState, width: Int(videoSize.width), height: Int(videoSize.height))
        
        // End the encoding of the command.
        computeCommandEncoder.endEncoding()
        
        // Commit the command buffer for execution.
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // The CVMetalTextures must stay alive until the GPU has finished with their MTLTextures
        withExtendedLifetime(inputCVTexture) {}
        withExtendedLifetime(maskCVTexture) {}
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
    private func makeMetalTexture(from pixelBuffer: CVPixelBuffer, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage) -> CVMetalTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, attributes, pixelFormat, width, height, 0, &cvTextureOut)
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
