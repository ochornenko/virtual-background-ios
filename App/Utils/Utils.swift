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

public func resizeCGImageToFit(_ inputCGImage: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage? {
    let scaleFactor = CGFloat(targetWidth) / CGFloat(inputCGImage.width)
    let newHeight = Int(CGFloat(inputCGImage.height) * scaleFactor)
    
    let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: inputCGImage.bitsPerComponent,
        bytesPerRow: 0,
        space: inputCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: inputCGImage.bitmapInfo.rawValue
    )
    
    guard let context = context else { return nil }
    
    // Fill background with black
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    
    // Draw the resized image centered vertically
    let originY = (targetHeight - newHeight) / 2
    context.draw(inputCGImage, in: CGRect(x: 0, y: originY, width: targetWidth, height: newHeight))
    
    return context.makeImage()
}

public func rotateIfNeeded(_ image: CGImage) -> CGImage {
    return image.width > image.height ? rotateCGImage(image, degrees: 270) ?? image : image
}

private func rotateCGImage(_ image: CGImage, degrees: CGFloat) -> CGImage? {
    let radians = degrees * (.pi / 180)
    
    // Swap width and height for 90° / 270° rotations
    let newWidth = degrees == 90 || degrees == 270 ? image.height : image.width
    let newHeight = degrees == 90 || degrees == 270 ? image.width : image.height
    
    let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: image.bitsPerComponent,
        bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: image.bitmapInfo.rawValue
    )
    
    guard let context = context else { return nil }
    
    // Move origin to center for proper rotation
    context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
    context.rotate(by: radians)
    
    // Draw the image centered after rotation
    context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    
    return context.makeImage()
}
