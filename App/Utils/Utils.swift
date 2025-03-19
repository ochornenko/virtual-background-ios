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
 Resizes a CVPixelBuffer to the specified width and height without cropping.
 This function acts as a wrapper around `resizePixelBuffer`, resizing the entire pixel buffer while maintaining efficiency.
 
 - Parameters:
 - pixelBuffer: The source CVPixelBuffer.
 - width: The target width for the resized pixel buffer.
 - height: The target height for the resized pixel buffer.
 - Returns: A new resized CVPixelBuffer, or `nil` if resizing fails.
 */
public func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer,
                              width: Int, height: Int) -> CVPixelBuffer? {
    return resizePixelBuffer(pixelBuffer, cropX: 0, cropY: 0,
                             cropWidth: CVPixelBufferGetWidth(pixelBuffer),
                             cropHeight: CVPixelBufferGetHeight(pixelBuffer),
                             scaleWidth: width, scaleHeight: height)
}

/**
 Crops and resizes a CVPixelBuffer to the specified dimensions.
 
 This function first extracts a cropped region from the source pixel buffer and then scales it to the target size.
 It uses the Accelerate framework's vImage API for efficient resizing.
 
 - Parameters:
 - srcPixelBuffer: The source CVPixelBuffer.
 - cropX: The x-coordinate of the top-left corner of the cropping region.
 - cropY: The y-coordinate of the top-left corner of the cropping region.
 - cropWidth: The width of the cropping region.
 - cropHeight: The height of the cropping region.
 - scaleWidth: The desired output width after resizing.
 - scaleHeight: The desired output height after resizing.
 - Returns: A new resized CVPixelBuffer, or `nil` if an error occurs.
 */
public func resizePixelBuffer(_ srcPixelBuffer: CVPixelBuffer,
                              cropX: Int,
                              cropY: Int,
                              cropWidth: Int,
                              cropHeight: Int,
                              scaleWidth: Int,
                              scaleHeight: Int) -> CVPixelBuffer? {
    let flags = CVPixelBufferLockFlags(rawValue: 0)
    guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(srcPixelBuffer, flags) else {
        return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(srcPixelBuffer, flags) }
    
    guard let srcData = CVPixelBufferGetBaseAddress(srcPixelBuffer) else {
        Log.error("Error: could not get pixel buffer base address")
        return nil
    }
    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPixelBuffer)
    let offset = cropY*srcBytesPerRow + cropX * 4
    var srcBuffer = vImage_Buffer(data: srcData.advanced(by: offset),
                                  height: vImagePixelCount(cropHeight),
                                  width: vImagePixelCount(cropWidth),
                                  rowBytes: srcBytesPerRow)
    
    let destBytesPerRow = scaleWidth * 4
    guard let destData = malloc(scaleHeight*destBytesPerRow) else {
        Log.error("Error: out of memory")
        return nil
    }
    var destBuffer = vImage_Buffer(data: destData,
                                   height: vImagePixelCount(scaleHeight),
                                   width: vImagePixelCount(scaleWidth),
                                   rowBytes: destBytesPerRow)
    
    let error = vImageScale_ARGB8888(&srcBuffer, &destBuffer, nil, vImage_Flags(0))
    if error != kvImageNoError {
        Log.error("Error: \(error)")
        free(destData)
        return nil
    }
    
    let releaseCallback: CVPixelBufferReleaseBytesCallback = { _, ptr in
        if let ptr = ptr {
            free(UnsafeMutableRawPointer(mutating: ptr))
        }
    }
    
    let pixelFormat = CVPixelBufferGetPixelFormatType(srcPixelBuffer)
    var dstPixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(nil, scaleWidth, scaleHeight,
                                              pixelFormat, destData,
                                              destBytesPerRow, releaseCallback,
                                              nil, nil, &dstPixelBuffer)
    if status != kCVReturnSuccess {
        Log.error("Error: could not create new pixel buffer")
        free(destData)
        return nil
    }
    return dstPixelBuffer
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
    
    // Ensure a valid color space
    let colorSpace = inputCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    
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
