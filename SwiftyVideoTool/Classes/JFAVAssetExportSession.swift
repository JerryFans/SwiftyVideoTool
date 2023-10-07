import AVFoundation
import Foundation



private let defaultVideoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecH264,
    AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 3000000,
        AVVideoExpectedSourceFrameRateKey: 30,
        AVVideoMaxKeyFrameIntervalKey: 30,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
    ]
]

private let defaultAudioSettings: [String: Any] = [
    AVEncoderBitRatePerChannelKey: 32000,
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVNumberOfChannelsKey: 2,
    AVSampleRateKey: 44100,
]

@objc public protocol JFAVAssetExportSessionDelegate: NSObjectProtocol {
    func exportSession(_ exportSession: JFAVAssetExportSession, renderFrame pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime, toBuffer renderBuffer: CVPixelBuffer)
}

@objcMembers
open class JFAVAssetExportSession: NSObject {
    public weak var delegate: JFAVAssetExportSessionDelegate?
    private let asset: AVAsset
    private var timeRange: CMTimeRange = .zero

    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    public var outputFileType: AVFileType?
    public var outputURL: URL?
    public var videoInputSettings: [String: Any]?
    public var videoSettings: [String: Any] = defaultVideoSettings
    public var audioSettings: [String: Any] = defaultAudioSettings
    public var metadata: [AVMetadataItem]?
    public var shouldOptimizeForNetworkUse: Bool = false
    public var error: Error? {
        if let error = _error {
            return error
        } else {
            return writer?.error ?? reader?.error
        }
    }
    public var progress: Float = 0 {
        didSet {
            self.progressHandle?(progress)
        }
    }
    public typealias JFAVAssetExprotProgressHandle = (_ progress: Float) -> Void
    public var progressHandle: JFAVAssetExprotProgressHandle?
    public var status: AVAssetExportSession.Status {
        switch writer?.status {
        case .unknown:
            return .unknown
        case .writing:
            return .exporting
        case .failed:
            return .failed
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .none:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private var _error: Error?
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderVideoCompositionOutput?
    private var audioOutput: AVAssetReaderAudioMixOutput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var inputQueue: DispatchQueue?
    private var completionHandler: (() -> Void)?
    private var duration: TimeInterval = 0
    private var lastSamplePresentationTime: CMTime = .zero

    public init(asset: AVAsset) {
        self.asset = asset
        self.timeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    static func exportSession(asset: AVAsset) -> JFAVAssetExportSession {
        return JFAVAssetExportSession(asset: asset)
    }
    
    public func exportAsynchronously(completionHandler handler: @escaping () -> Void) {
        DispatchQueue.global().async {
            self.cancelExport()
            self.completionHandler = handler
            assert(self.completionHandler != nil)
            
            if self.outputURL == nil {
                self._error = NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "Output URL not set"])
                self.completionHandler?()
                return
            }

            do {
                self.reader = try AVAssetReader(asset: self.asset)
            } catch let error {
                self._error = error as NSError
                self.completionHandler?()
                return
            }

            do {
                self.writer = try AVAssetWriter(url: self.outputURL!, fileType: self.outputFileType ?? .mp4)
            } catch let error {
                self._error = error
                self.completionHandler?()
                return
            }
            
            if self.writer == nil || self.reader == nil {
                self._error = NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: "reader or write is nil"])
                self.completionHandler?()
                return
            }

            self.reader?.timeRange = self.timeRange
            self.writer?.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse
            self.writer?.metadata = self.metadata ?? []

            let videoTracks = self.asset.tracks(withMediaType: AVMediaType.video)
            
            if CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVEINFINITY(self.timeRange.duration) {
                self.duration = CMTimeGetSeconds(self.timeRange.duration)
            } else {
                self.duration = CMTimeGetSeconds(self.asset.duration)
            }
            
            
            if videoTracks.count > 0 {
                
                if self.videoSettings[AVVideoWidthKey] == nil || self.videoSettings[AVVideoHeightKey] == nil {
                    let size = self.getVideoNaturalSize()
                    self.videoSettings[AVVideoWidthKey] = size.width
                    self.videoSettings[AVVideoHeightKey] = size.height
                }
                
                let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: self.videoInputSettings)
                self.videoOutput = videoOutput
                videoOutput.alwaysCopiesSampleData = false
                if let videoComposition = self.videoComposition {
                    self.videoOutput?.videoComposition = videoComposition
                } else {
                    self.videoOutput?.videoComposition = self.buildDefaultVideoComposition()
                }

                if self.reader!.canAdd(videoOutput) {
                    self.reader!.add(videoOutput)
                }

                let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: self.videoSettings)
                self.videoInput = videoInput
                self.videoInput?.expectsMediaDataInRealTime = false
                if self.writer!.canAdd(videoInput) {
                    self.writer!.add(videoInput)
                }
                var pixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    "IOSurfaceOpenGLESTextureCompatibility": true,
                    "IOSurfaceOpenGLESFBOCompatibility": true
                ]
                if let size = videoOutput.videoComposition?.renderSize {
                    pixelBufferAttributes[kCVPixelBufferWidthKey as String] = size.width
                    pixelBufferAttributes[kCVPixelBufferHeightKey as String] = size.height
                }
                self.videoPixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelBufferAttributes)
            }

            let audioTracks = self.asset.tracks(withMediaType: AVMediaType.audio)
            if audioTracks.count > 0 {
                let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
                self.audioOutput = audioOutput
                self.audioOutput?.alwaysCopiesSampleData = false
                self.audioOutput?.audioMix = self.audioMix
                if self.reader!.canAdd(audioOutput) {
                    self.reader!.add(audioOutput)
                }
            } else {
                self.audioOutput = nil
            }

            if self.audioOutput != nil {
                let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: self.audioSettings)
                self.audioInput = audioInput
                self.audioInput?.expectsMediaDataInRealTime = false
                if self.writer!.canAdd(audioInput) {
                    self.writer!.add(audioInput)
                }
            }

            self.writer?.startWriting()
            self.reader?.startReading()
            self.writer?.startSession(atSourceTime: self.timeRange.start)

            var videoCompleted = false
            var audioCompleted = false
            self.inputQueue = DispatchQueue(label: "VideoEncoderInputQueue", qos: .default, attributes: [])
            if videoTracks.count > 0 {
                self.videoInput?.requestMediaDataWhenReady(on: self.inputQueue!) {
                    [weak self] in
                    guard let strongSelf = self else { return }
                    if !strongSelf.encodeReadySamples(from: strongSelf.videoOutput, to: strongSelf.videoInput) {
                        JFAVAssetExportSession.synchronized(strongSelf) {
                            videoCompleted = true
                            if audioCompleted {
                                strongSelf.finish()
                            }
                        }
                    }
                }
            } else {
                videoCompleted = true
            }

            if self.audioOutput == nil {
                audioCompleted = true
            } else {
                self.audioInput?.requestMediaDataWhenReady(on: self.inputQueue!) {
                    [weak self] in
                    guard let strongSelf = self else { return }
                    if !strongSelf.encodeReadySamples(from: strongSelf.audioOutput, to: strongSelf.audioInput) {
                        JFAVAssetExportSession.synchronized(strongSelf) {
                            audioCompleted = true
                            if videoCompleted {
                                strongSelf.finish()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private static func synchronized(_ lock: AnyObject, closure: () -> Void) {
        objc_sync_enter(lock)
        closure()
        objc_sync_exit(lock)
    }

    func cancelExport() {
        if self.inputQueue != nil {
            self.inputQueue?.async {
                self.writer?.cancelWriting()
                self.reader?.cancelReading()
                self.complete()
                self.reset()
            }
        }
    }
    
    private func getVideoNaturalSize() -> CGSize {
        guard let videoTrack = self.asset.tracks(withMediaType: AVMediaType.video).first else {
            return .zero
        }
        return videoTrack.naturalSize
    }
    
    func buildDefaultVideoComposition() -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        guard let videoTrack = self.asset.tracks(withMediaType: AVMediaType.video).first else {
            return videoComposition
        }
        
        var trackFrameRate: Float = 0
        if let videoCompressionProperties = self.videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any],
            let frameRate = videoCompressionProperties[AVVideoAverageNonDroppableFrameRateKey] as? NSNumber {
            trackFrameRate = frameRate.floatValue
        } else {
            trackFrameRate = videoTrack.nominalFrameRate
        }
        
        if trackFrameRate == 0 {
            trackFrameRate = 30
        }
        
        var naturalSize = videoTrack.naturalSize
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(trackFrameRate))
        let targetSize = CGSize(width: self.videoSettings[AVVideoWidthKey] as? CGFloat ?? naturalSize.width, height: self.videoSettings[AVVideoHeightKey] as? CGFloat ?? naturalSize.height)
        
        var transform = videoTrack.preferredTransform
        
        if transform.ty == -560 {
            transform.ty = 0
        }
        
        if transform.tx == -560 {
            transform.tx = 0
        }
        
        let videoAngleInDegree = atan2(transform.b, transform.a) * 180 / .pi
        if videoAngleInDegree == 90 || videoAngleInDegree == -90 {
            let width = naturalSize.width
            naturalSize.width = naturalSize.height
            naturalSize.height = width
        }
        videoComposition.renderSize = naturalSize
        
        let ratio: Float
        let xratio = targetSize.width / naturalSize.width
        let yratio = targetSize.height / naturalSize.height
        ratio = Float(min(xratio, yratio))
        
        let postWidth = naturalSize.width * CGFloat(ratio)
        let postHeight = naturalSize.height * CGFloat(ratio)
        let transx = (targetSize.width - postWidth) / 2
        let transy = (targetSize.height - postHeight) / 2
        
        var matrix = CGAffineTransform(translationX: transx / xratio, y: transy / yratio)
        matrix = matrix.scaledBy(x: CGFloat(ratio) / xratio, y: CGFloat(ratio) / yratio)
        transform = transform.concatenating(matrix)
        
        let passThroughInstruction = AVMutableVideoCompositionInstruction()
        passThroughInstruction.timeRange = CMTimeRangeMake(start: .zero, duration: self.asset.duration)
        
        let passThroughLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        passThroughLayer.setTransform(transform, at: .zero)
        
        passThroughInstruction.layerInstructions = [passThroughLayer]
        videoComposition.instructions = [passThroughInstruction]
        
        return videoComposition
    }

    private func complete() {
        if writer?.status == .failed || writer?.status == .cancelled {
            try? FileManager.default.removeItem(at: outputURL!)
        }

        completionHandler?()
        completionHandler = nil
    }

    private func reset() {
        _error = nil
        progress = 0
        reader = nil
        videoOutput = nil
        audioOutput = nil
        writer = nil
        videoInput = nil
        videoPixelBufferAdaptor = nil
        audioInput = nil
        inputQueue = nil
        completionHandler = nil
    }


    func encodeReadySamples(from output: AVAssetReaderOutput?, to input: AVAssetWriterInput?) -> Bool {
        guard let reader = self.reader else { return false }
        guard let writer = self.writer else { return false }
        while input?.isReadyForMoreMediaData ?? false {
            if let sampleBuffer = output?.copyNextSampleBuffer() {
                var handled = false
                var error = false

                if reader.status != .reading || writer.status != .writing {
                    handled = true
                    error = true
                }

                if !handled && output === self.videoOutput {
                    lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    lastSamplePresentationTime = CMTimeSubtract(lastSamplePresentationTime, self.timeRange.start)
                    self.progress = Float(duration == 0 ? 1 : CMTimeGetSeconds(lastSamplePresentationTime) / duration)
                    if self.delegate?.responds(to: #selector(JFAVAssetExportSessionDelegate.exportSession(_:renderFrame:withPresentationTime:toBuffer:))) ?? false, let buffer = self.videoPixelBufferAdaptor?.pixelBufferPool, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        var renderBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, buffer, &renderBuffer)
                        if let renderBuffer {
                            self.delegate?.exportSession(self, renderFrame: pixelBuffer, withPresentationTime: lastSamplePresentationTime, toBuffer: renderBuffer)
                            if !(self.videoPixelBufferAdaptor?.append(renderBuffer, withPresentationTime: lastSamplePresentationTime) ?? false) {
                                error = true
                            }
                        } else {
                            error = true
                        }
                        handled = true
                    }
                }
                if !handled && !(input?.append(sampleBuffer) ?? false) {
                    error = true
                }

                if error {
                    return false
                }
            } else {
                input?.markAsFinished()
                return false
            }
        }

        return true
    }

    func finish() {
        if self.reader?.status == .cancelled || self.writer?.status == .cancelled {
            return
        }

        if self.writer?.status == .failed {
            complete()
        } else if self.reader?.status == .failed {
            self.writer?.cancelWriting()
            complete()
        } else {
            self.writer?.finishWriting {
                self.complete()
            }
        }
    }
}
