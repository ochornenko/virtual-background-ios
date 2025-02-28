//
//  Utils.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/26/25.
//

import Accelerate
import MetalKit

/**
 Resizes a CVPixelBuffer to a new width and height.
 */
public func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer,
                              width: Int, height: Int) -> CVPixelBuffer? {
    return resizePixelBuffer(pixelBuffer, cropX: 0, cropY: 0,
                             cropWidth: CVPixelBufferGetWidth(pixelBuffer),
                             cropHeight: CVPixelBufferGetHeight(pixelBuffer),
                             scaleWidth: width, scaleHeight: height)
}

/**
 First crops the pixel buffer, then resizes it.
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

private let textureLoader: MTKTextureLoader = {
    return MTKTextureLoader(device: MTLCreateSystemDefaultDevice()!)
}()

/**
 Loads a texture from the specified image.
 */
public func loadTexture(image: CGImage) -> MTLTexture? {
    do {
        return try textureLoader.newTexture(cgImage: image, options: [
            MTKTextureLoader.Option.SRGB : NSNumber(value: false)
        ])
    } catch {
        Log.error("Error: could not load texture \(error)")
        return nil
    }
}

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
