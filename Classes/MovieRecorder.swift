//
//  MovieRecorder.swift
//  RosyWriter
//
//  Created by Waleed Abdulla on 10/19/14.
//
//

import Foundation
import AVFoundation

//#import <AVFoundation/AVAssetWriter.h>
//#import <AVFoundation/AVAssetWriterInput.h>

//#import <AVFoundation/AVMediaFormat.h>
//#import <AVFoundation/AVVideoSettings.h>
//#import <AVFoundation/AVAudioSettings.h>

//#include <objc/runtime.h> // for objc_loadWeak() and objc_storeWeak()

let LOG_STATUS_TRANSITIONS = 0

// internal state machine
enum MovieRecorderStatus: Int {
    case Idle = 0
    case PreparingToRecord
    case Recording
    case FinishingRecordingPart1 // waiting for inflight buffers to be appended
    case FinishingRecordingPart2 // calling finish writing on the asset writer
    case Finished	// terminal state
    case Failed		// terminal state
}

// Swifth doesn't have an equivalent to Objective C's @synchronized. This is a simple implementation from
// http://stackoverflow.com/questions/24045895/what-is-the-swift-equivalent-to-objective-cs-synchronized
// Not identical to the Objective-C implementation, but close enough.
func synchronized(lock: AnyObject, closure: () -> ()) {
    objc_sync_enter(lock)
    closure()
    objc_sync_exit(lock)
}


@objc protocol MovieRecorderDelegate {
    func movieRecorderDidFinishPreparing(recorder : MovieRecorder)
    func movieRecorder(recorder : MovieRecorder, didFailWithError error:NSError?)
    func movieRecorderDidFinishRecording(recorder : MovieRecorder)
}


class MovieRecorder: NSObject {
    private var _status : MovieRecorderStatus = .Idle
    
    private var _delegate : MovieRecorderDelegate?

    private var _delegateCallbackQueue : dispatch_queue_t?
    
    private var _writingQueue : dispatch_queue_t
    
    private var _URL : NSURL
    
    private var _assetWriter : AVAssetWriter!
    private var _haveStartedSession : Bool = false
    
    private var _audioTrackSourceFormatDescription : CMFormatDescription?
    private var _audioTrackSettings : NSDictionary?
    private var _audioInput : AVAssetWriterInput!
    
    private var _videoTrackSourceFormatDescription : CMFormatDescription?
    private var _videoTrackTransform : CGAffineTransform
    private var _videoTrackSettings : NSDictionary?
    private var _videoInput : AVAssetWriterInput!

    
    init(URL : NSURL) {
        _writingQueue = dispatch_queue_create("com.apple.sample.movierecorder.writing", DISPATCH_QUEUE_SERIAL)
        _videoTrackTransform = CGAffineTransformIdentity
        _URL = URL
    }
    
    
    func addVideoTrackWithSourceFormatDescription(formatDescription:CMFormatDescription, transform:CGAffineTransform, settings videoSettings:NSDictionary) {
    
        synchronized(self) {
            if self._status != .Idle {
                NSException(name: NSInternalInconsistencyException,
                    reason:"Cannot add tracks while not idle",
                    userInfo:nil).raise()
                return
            }
    
            if self._videoTrackSourceFormatDescription != nil {
                NSException(name:NSInternalInconsistencyException,
                    reason:"Cannot add more than one video track",
                    userInfo:nil).raise()
                return
            }
    
            self._videoTrackSourceFormatDescription = formatDescription
            self._videoTrackTransform = transform
            self._videoTrackSettings = videoSettings
        }
    }
    
    
    func addAudioTrackWithSourceFormatDescription(formatDescription:CMFormatDescription,
        settings audioSettings:NSDictionary) {
    
        synchronized(self) {
            if self._status != .Idle {
                NSException(name:NSInternalInconsistencyException,
                    reason:"Cannot add tracks while not idle",
                    userInfo:nil).raise()
                return
            }
    
            if self._audioTrackSourceFormatDescription != nil {
                NSException(name: NSInternalInconsistencyException,
                    reason:"Cannot add more than one audio track",
                    userInfo:nil).raise()
                return
            }
    
            self._audioTrackSourceFormatDescription = formatDescription
            self._audioTrackSettings = audioSettings
        }
    }
    
    
    func delegate() -> MovieRecorderDelegate? {
        return _delegate
    }
    
    
    func setDelegate(delegate: MovieRecorderDelegate, callbackQueue delegateCallbackQueue:dispatch_queue_t){
        synchronized( self ) {
            self._delegate = delegate
            self._delegateCallbackQueue = delegateCallbackQueue
        }
    }

 
    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishPreparing: or recorder:didFailWithError: method will be called.
    func prepareToRecord() {
        synchronized( self ) {
            if self._status != .Idle {
                NSException(name:NSInternalInconsistencyException,
                    reason:"Already prepared, cannot prepare again",
                    userInfo:nil).raise()
                return
            }
    
            self.transitionToStatus(.PreparingToRecord, error: nil)
        }
    
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)) {
    
            autoreleasepool {
                var error : NSError?
                
                // AVAssetWriter will not write over an existing file.
                NSFileManager.defaultManager().removeItemAtURL(self._URL, error:nil)
                self._assetWriter = AVAssetWriter(URL:self._URL, fileType:AVFileTypeQuickTimeMovie, error:&error)
    
                // Create and add inputs
                if error == nil && self._videoTrackSourceFormatDescription != nil {
                    self.setupAssetWriterVideoInputWithSourceFormatDescription(self._videoTrackSourceFormatDescription!,
                        transform:self._videoTrackTransform,
                        settings:self._videoTrackSettings,
                        error: &error)
                }
    
                if error == nil && self._audioTrackSourceFormatDescription != nil {
                    self.setupAssetWriterAudioInputWithSourceFormatDescription(self._audioTrackSourceFormatDescription!,
                        settings:self._audioTrackSettings,
                        error: &error)
                }
    
                if error == nil {
                    var success:Bool = self._assetWriter.startWriting()
                    if !success {
                        error = self._assetWriter.error
                    }
                }
    
                synchronized( self ) {
                    if error != nil {
                        self.transitionToStatus(.Failed, error:error)
                    }
                    else {
                        self.transitionToStatus(.Recording, error:nil)
                    }
                }
            }
        }
    }
    
    
    func appendVideoSampleBuffer(sampleBuffer: CMSampleBuffer?) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType:AVMediaTypeVideo)
    }

    
    func appendVideoPixelBuffer(pixelBuffer: CVPixelBufferRef, withPresentationTime presentationTime:CMTime)
    {
        var timingInfo: CMSampleTimingInfo = CMSampleTimingInfo(
            duration: kCMTimeInvalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: kCMTimeInvalid)
    
        var unmanagedSampleBuffer: Unmanaged<CMSampleBuffer>?
        
        var err : OSStatus = CMSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer as CVImageBuffer,
            Boolean(1),
            nil,
            nil,
            _videoTrackSourceFormatDescription! as CMVideoFormatDescription!,
            &timingInfo,
            &unmanagedSampleBuffer)

        var sampleBuffer : CMSampleBuffer? = unmanagedSampleBuffer!.takeRetainedValue()
        if sampleBuffer != nil {
            self.appendSampleBuffer(sampleBuffer, ofMediaType:AVMediaTypeVideo)
        }
        else {
            NSException(name:NSInvalidArgumentException,
            reason: "sample buffer create failed \(err)",
            userInfo:nil).raise()
            return;
        }
    }
    
    
    func appendAudioSampleBuffer(sampleBuffer: CMSampleBufferRef) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType:AVMediaTypeAudio)
    }
    

    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishRecording: or recorder:didFailWithError: method will be called.
    func finishRecording() {
        synchronized(self) {
            var shouldFinishRecording = false
            switch ( self._status ) {
            case .Idle, .PreparingToRecord, .FinishingRecordingPart1, .FinishingRecordingPart2, .Finished:
                NSException(name:NSInternalInconsistencyException,
                    reason:"Not recording",
                    userInfo:nil).raise()
            case .Failed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                NSLog("Recording has failed, nothing to do")
            case .Recording:
                shouldFinishRecording = true
            }
    
            if shouldFinishRecording {
                self.transitionToStatus(.FinishingRecordingPart1, error:nil)
            }
            else {
                return
            }
        }
    
        dispatch_async(_writingQueue) {
            autoreleasepool {
                synchronized(self) {
                    // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                    if self._status != .FinishingRecordingPart1 {
                        return
                    }
    
                    // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                    // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
                    self.transitionToStatus(.FinishingRecordingPart2, error:nil)
                }
    
                self._assetWriter.finishWritingWithCompletionHandler(){
                    synchronized(self) {
                        var error = self._assetWriter.error
                        if error != nil{
                            self.transitionToStatus(.Failed, error:error)
                        }
                        else {
                            self.transitionToStatus(.Finished, error:nil)
                        }
                    }
                }
            }
        }
    }


    private func appendSampleBuffer(sampleBuffer: CMSampleBuffer?, ofMediaType mediaType:String) {
        if sampleBuffer == nil {
            NSException(name:NSInvalidArgumentException,
                reason:"NULL sample buffer", userInfo:nil).raise()
            return
        }
    
        synchronized(self) {
            if self._status.toRaw() < MovieRecorderStatus.Recording.toRaw() {
                NSException(name:NSInternalInconsistencyException,
                    reason:"Not ready to record yet", userInfo:nil).raise()
                return
            }
        }
    
        dispatch_async(_writingQueue) {
    
            autoreleasepool {
                synchronized(self) {
                    // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                    // Because of this we are lenient when samples are appended and we are no longer recording.
                    // Instead of throwing an exception we just return.
                    if self._status.toRaw() > MovieRecorderStatus.FinishingRecordingPart1.toRaw() {
                        return
                    }
                }
    
                if !self._haveStartedSession {
                    self._assetWriter.startSessionAtSourceTime(
                        CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    self._haveStartedSession = true
                }
    
                var input: AVAssetWriterInput = (mediaType == AVMediaTypeVideo) ? self._videoInput : self._audioInput
    
                if input.readyForMoreMediaData {
                    var success = input.appendSampleBuffer(sampleBuffer)
                    if !success {
                        var error = self._assetWriter.error
                        synchronized( self ) {
                            self.transitionToStatus(.Failed, error:error)
                        }
                    }
                }
                else {
                    NSLog("%@ input not ready for more media data, dropping buffer", mediaType)
                }
            }
        }
    }
    
    // call under @synchonized( self )
    func transitionToStatus(newStatus:MovieRecorderStatus, error:NSError?) {
        var shouldNotifyDelegate = false
        
        NSLog("MovieRecorder state transition: %@->%@", self.stringForStatus(_status), self.stringForStatus(newStatus))
        
        if newStatus != _status {
            // terminal states
            if ( newStatus == .Finished ) || ( newStatus == .Failed ) {
                shouldNotifyDelegate = true
                // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
                
                dispatch_async(_writingQueue) {
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .Failed {
                        NSFileManager.defaultManager().removeItemAtURL(self._URL, error:nil)
                    }
                }
                
                if let e = error {
                    NSLog("MovieRecorder error: %@, code: %i", e, e.code )
                }
            }
            else if newStatus == .Recording {
                shouldNotifyDelegate = true
            }
            
            _status = newStatus
        }
        
        if shouldNotifyDelegate && self.delegate() != nil {
            dispatch_async( _delegateCallbackQueue) {
                autoreleasepool {
                    switch newStatus {
                    case .Recording:
                        self.delegate()!.movieRecorderDidFinishPreparing(self)
                        
                    case .Finished:
                        self.delegate()!.movieRecorderDidFinishRecording(self)
                        
                    case .Failed:
                        self.delegate()!.movieRecorder(self, didFailWithError:error)
                        
                    default:
                        break
                    }
                }
            }
        }
    }
    
    func stringForStatus(status:MovieRecorderStatus) -> String {
        var statusString: String
        
        switch status {
        case .Idle:
            statusString = "Idle"
        case .PreparingToRecord:
            statusString = "PreparingToRecord"
        case .Recording:
            statusString = "Recording"
        case .FinishingRecordingPart1:
            statusString = "FinishingRecordingPart1"
        case .FinishingRecordingPart2:
            statusString = "FinishingRecordingPart2"
        case .Finished:
            statusString = "Finished"
        case .Failed:
            statusString = "Failed"
        default:
            statusString = "Unknown"
        }
        return statusString
    }
    
    
    func setupAssetWriterAudioInputWithSourceFormatDescription(audioFormatDescription:CMFormatDescription,
        var settings audioSettings:NSDictionary?,
        error errorOut:NSErrorPointer) -> Bool
    {
        if audioSettings == nil {
            NSLog("No audio settings provided, using default settings")
            audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC]
        }
    
        if _assetWriter.canApplyOutputSettings(audioSettings, forMediaType:AVMediaTypeAudio) {
            _audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioSettings, sourceFormatHint: audioFormatDescription)
            _audioInput.expectsMediaDataInRealTime = true
    
            if _assetWriter.canAddInput(_audioInput) {
                _assetWriter.addInput(_audioInput)
            }
            else {
                if errorOut != nil {
                    errorOut.memory = self.dynamicType.cannotSetupInputError()
                }
                return false
            }
        }
        else {
            if errorOut != nil {
                errorOut.memory = self.dynamicType.cannotSetupInputError()
            }
            return false
        }
    
        return true
    }


    func setupAssetWriterVideoInputWithSourceFormatDescription(
        videoFormatDescription:CMFormatDescription,
        transform:CGAffineTransform,
        var settings videoSettings:NSDictionary?,
        error errorOut:NSErrorPointer) -> Bool
    {
        // If video settings are not provided, create default settings.
        if videoSettings == nil {
            var bitsPerPixel: Float
            var dimensions: CMVideoDimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription)
            var numPixels: Int = Int(dimensions.width) * Int(dimensions.height)
            var bitsPerSecond: Int
    
            NSLog("No video settings provided, using default settings")
    
            // Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
            if numPixels < ( 640 * 480 ) {
                bitsPerPixel = 4.05 // This bitrate approximately matches the quality produced by AVCaptureSessionPresetMedium or Low.
            }
            else {
                bitsPerPixel = 10.1 // This bitrate approximately matches the quality produced by AVCaptureSessionPresetHigh.
            }
    
            bitsPerSecond = Int(Float(numPixels) * bitsPerPixel)
    
            var compressionProperties: NSDictionary = [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30]
    
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecH264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: compressionProperties]
        }
    
        if _assetWriter.canApplyOutputSettings(videoSettings, forMediaType:AVMediaTypeVideo) {
            _videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo,
                outputSettings: videoSettings,
                sourceFormatHint: videoFormatDescription)
            _videoInput.expectsMediaDataInRealTime = true
            _videoInput.transform = transform
    
            if _assetWriter.canAddInput(_videoInput) {
                _assetWriter.addInput(_videoInput)
            }
            else {
                if errorOut != nil {
                    errorOut.memory = self.dynamicType.cannotSetupInputError()
                }
                return false
            }
        }
        else {
            if errorOut != nil {
                errorOut.memory = self.dynamicType.cannotSetupInputError()
            }
            return false
        }
    
        return true
    }

    private class func cannotSetupInputError() -> NSError
    {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment:"")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment:"")
        let errorDict: NSDictionary = [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }
    
    private func teardownAssetWriterAndInputs() {
        // TODO: 
        //_videoInput = nil
        //_audioInput = nil
        //_assetWriter = nil
    }
    
    

}


/*




        - (void)dealloc
            {
                objc_storeWeak( &_delegate, nil ); // unregister _delegate as a weak reference

                [_delegateCallbackQueue release];

                [_writingQueue release];

                [self teardownAssetWriterAndInputs];

                if ( _audioTrackSourceFormatDescription ) {
                    CFRelease( _audioTrackSourceFormatDescription );
                }
                [_audioTrackSettings release];

                if ( _videoTrackSourceFormatDescription ) {
                    CFRelease( _videoTrackSourceFormatDescription );
                }
                [_videoTrackSettings release];

                [_URL release];

                [super dealloc];
        }

#pragma mark -
#pragma mark Internal



@end
*/
