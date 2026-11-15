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

import Accelerate
import MetalKit

/**
 Creates a pool of Metal-compatible BGRA pixel buffers so frames can reuse memory instead of allocating it.
 
 - Parameters:
 - width: The width of the pixel buffers in the pool.
 - height: The height of the pixel buffers in the pool.
 - Returns: A new CVPixelBufferPool, or `nil` if creation fails.
 */
public func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    var pool: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
        Log.error("Error: could not create pixel buffer pool")
        return nil
    }
    return pool
}

/**
 Takes a pixel buffer from the pool, allocating a new one only if all pooled buffers are in use.
 
 - Parameter pool: The pool to take the pixel buffer from.
 - Returns: A pixel buffer, or `nil` if allocation fails.
 */
public func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else {
        Log.error("Error: could not create pixel buffer from pool")
        return nil
    }
    return pixelBuffer
}

/**
 Scales the entire source pixel buffer into the destination pixel buffer without cropping.
 Both pixel buffers must use a 4-channel, 8-bit pixel format such as BGRA.
 It uses the Accelerate framework's vImage API for efficient resizing.
 
 - Parameters:
 - srcPixelBuffer: The source CVPixelBuffer.
 - dstPixelBuffer: The CVPixelBuffer to write the scaled image into.
 - Returns: `true` if scaling succeeded.
 */
public func resizePixelBuffer(_ srcPixelBuffer: CVPixelBuffer, into dstPixelBuffer: CVPixelBuffer) -> Bool {
    guard CVPixelBufferLockBaseAddress(srcPixelBuffer, .readOnly) == kCVReturnSuccess else {
        return false
    }
    defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, .readOnly) }
    
    guard CVPixelBufferLockBaseAddress(dstPixelBuffer, []) == kCVReturnSuccess else {
        return false
    }
    defer { CVPixelBufferUnlockBaseAddress(dstPixelBuffer, []) }
    
    guard let srcData = CVPixelBufferGetBaseAddress(srcPixelBuffer),
          let dstData = CVPixelBufferGetBaseAddress(dstPixelBuffer) else {
        Log.error("Error: could not get pixel buffer base address")
        return false
    }
    
    var srcBuffer = vImage_Buffer(data: srcData,
                                  height: vImagePixelCount(CVPixelBufferGetHeight(srcPixelBuffer)),
                                  width: vImagePixelCount(CVPixelBufferGetWidth(srcPixelBuffer)),
                                  rowBytes: CVPixelBufferGetBytesPerRow(srcPixelBuffer))
    var dstBuffer = vImage_Buffer(data: dstData,
                                  height: vImagePixelCount(CVPixelBufferGetHeight(dstPixelBuffer)),
                                  width: vImagePixelCount(CVPixelBufferGetWidth(dstPixelBuffer)),
                                  rowBytes: CVPixelBufferGetBytesPerRow(dstPixelBuffer))
    
    let error = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
    guard error == kvImageNoError else {
        Log.error("Error: \(error)")
        return false
    }
    return true
}

/**
 Resizes a CGImage to completely fill the target dimensions while maintaining the aspect ratio.
 This function scales the image so that it completely covers the target size, potentially cropping excess areas.
 
 - Parameters:
 - inputCGImage: The original CGImage to be resized.
 - targetWidth: The desired width of the output image.
 - targetHeight: The desired height of the output image.
 - Returns: A new CGImage resized to fill the target dimensions, or `nil` if resizing fails.
 */
public func resizeCGImageToFill(_ inputCGImage: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage? {
    let widthScale = CGFloat(targetWidth) / CGFloat(inputCGImage.width)
    let heightScale = CGFloat(targetHeight) / CGFloat(inputCGImage.height)
    let scaleFactor = max(widthScale, heightScale) // Ensure the image fills the target size
    
    let newWidth = Int(CGFloat(inputCGImage.width) * scaleFactor)
    let newHeight = Int(CGFloat(inputCGImage.height) * scaleFactor)
    
    // The source color space may be grayscale, CMYK or indexed, none of which support an 8-bit RGBA bitmap context
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    
    // Use a compatible bitmap info
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    
    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8, // 8-bit per component (standard for ARGB)
        bytesPerRow: 0, // Automatically determined
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }
    
    // Calculate cropping offset to center the image
    let xOffset = (newWidth - targetWidth) / 2
    let yOffset = (newHeight - targetHeight) / 2
    let drawRect = CGRect(x: -xOffset, y: -yOffset, width: newWidth, height: newHeight)
    
    // Draw the image to fill the entire context
    context.draw(inputCGImage, in: drawRect)
    
    return context.makeImage()
}

/**
 Rotates the given UIImage if its orientation is not `.up`.
 If the image is already upright, it returns the original image.
 This function creates a new image context, draws the image into it,
 and retrieves the correctly oriented image.
 
 - Parameter image: The UIImage to be rotated if needed.
 - Returns: A new UIImage with corrected orientation, or the original image if no rotation was needed.
 */
public func rotateIfNeeded(_ image: UIImage?) -> UIImage? {
    guard let image = image, image.imageOrientation != .up else {
        return image
    }
    
    UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
    image.draw(in: CGRect(origin: .zero, size: image.size))
    let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    
    return rotatedImage ?? image
}
