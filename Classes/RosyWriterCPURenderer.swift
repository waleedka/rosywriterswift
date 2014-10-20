//
//  RosyWriterCPURenderer.swift
//  RosyWriter
//
//  Created by Waleed Abdulla on 10/18/14.
//
//

import Foundation
import CoreMedia
import CoreVideo


internal class RosyWriterCPURenderer : NSObject, RosyWriterRenderer {
    
    var operatesInPlace :Bool {
        return true
    }
    
    var inputPixelFormat: FourCharCode {
        return FourCharCode(kCVPixelFormatType_32BGRA)
    }
    
    
    func prepareForInputWithFormatDescription(inputFormatDescription: CMFormatDescriptionRef, outputRetainedBufferCountHint: size_t) {
        // nothing to do, we are stateless
    }
    
    func reset() {
        // nothing to do, we are stateless
    }
    
    func copyRenderedPixelBuffer(pixelBuffer: CVPixelBuffer) -> Unmanaged<CVPixelBuffer> {
        
        let kBytesPerPixel: Int = 4
        
        CVPixelBufferLockBaseAddress(pixelBuffer, 0)
        
        let bufferWidth = CVPixelBufferGetWidth( pixelBuffer )
        let bufferHeight = CVPixelBufferGetHeight( pixelBuffer )
        let bytesPerRow = CVPixelBufferGetBytesPerRow( pixelBuffer )
        let baseAddress: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>(CVPixelBufferGetBaseAddress( pixelBuffer ))
        
        for var row:UInt = 0; row < bufferHeight; row++ {
            var pixel: UnsafeMutablePointer<UInt8> = baseAddress + Int(row * bytesPerRow)
            for var column:UInt = 0; column < bufferWidth; column++ {
                (pixel + 1).memory = 0 // De-green (second pixel in BGRA is green)
                pixel += kBytesPerPixel;
            }
        }
        
        CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 )
        
        return Unmanaged<CVPixelBuffer>.passRetained(pixelBuffer)
    }

}