//
//  JFVideoTool.swift
//  SwiftyVideoTool
//
//  Created by JerryFans on 2023/10/8.
//

import UIKit
import AVFoundation
import AudioToolbox
import VideoToolbox
import JRBaseKit

public enum JFWaterMarkPosition {
    
    case topLeft(top: CGFloat, left: CGFloat)
    case topRight(top: CGFloat, right: CGFloat)
    case bottomLeft(bottom: CGFloat, left: CGFloat)
    case bottomRight(bottom: CGFloat, right: CGFloat)
    case absolute(frame: CGRect)
    
    func calcuateFrame(with waterMarkSize: CGSize, canvasSize: CGSize) -> CGRect {
        switch self {
        case .topLeft(top: let top, left: let left):
            return CGRect(x: left, y: canvasSize.height - top - waterMarkSize.height, width: waterMarkSize.width, height: waterMarkSize.height)
        case .topRight(top: let top, right: let right):
            return CGRect(x: canvasSize.width - waterMarkSize.width - right, y: canvasSize.height - top - waterMarkSize.height, width: waterMarkSize.width, height: waterMarkSize.height)
        case .bottomLeft(bottom: let bottom, left: let left):
            return CGRect(x: left, y: bottom, width: waterMarkSize.width, height: waterMarkSize.height)
        case .bottomRight(bottom: let bottom, right: let right):
            return CGRect(x: canvasSize.width - waterMarkSize.width - right, y: bottom, width: waterMarkSize.width, height: waterMarkSize.height)
        case .absolute(frame: let frame):
            return frame
        }
    }
}

public class JFVideoTool: NSObject {
    
    public class func addtWatermark(videoInputUrl: URL,
                             outPutFilePath: String,
                                    waterMarkView: @escaping () -> (waterMark :UIView,pos :JFWaterMarkPosition),
                             progressHandler: @escaping (CGFloat) -> Void,
                             completionHandler: @escaping (Bool, URL?) -> Void) {
        let size = Self.getSize(videoInputUrl: videoInputUrl)
        let picLayer = CALayer()
        
        let result = waterMarkView()
        let containerView = result.waterMark
        let pos = result.pos
        
        picLayer.contents = containerView.jf.syncSnapshotImage()?.cgImage
        
        let wmSize = containerView.jf.size
        
        picLayer.frame = pos.calcuateFrame(with: wmSize, canvasSize: size)
        
        let overlayLayer = CALayer()
        overlayLayer.addSublayer(picLayer)
        overlayLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        overlayLayer.masksToBounds = true
        
        Self.addWatermark(with: overlayLayer, videoInputUrl: videoInputUrl, outPutFilePath: outPutFilePath, progressHandler: progressHandler) { success, outputFileUrl in
            completionHandler(success, outputFileUrl)
        }
    }
    
    class func addWatermark(with overlayLayer: CALayer, videoInputUrl: URL, outPutFilePath: String?, progressHandler: ((CGFloat) -> Void)?, completionHandler: @escaping (Bool, URL?) -> Void) {
        let videoAsset = AVAsset(url: videoInputUrl)
        let mixComposition = AVMutableComposition()
        let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try? videoTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: videoAsset.duration), of: videoAsset.tracks(withMediaType: .video).first!, at: .zero)
        let audioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try? audioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: videoAsset.duration), of: videoAsset.tracks(withMediaType: .audio).first!, at: .zero)
        
        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRangeMake(start: .zero, duration: videoAsset.duration)
        let videoLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack!)
        videoLayerInstruction.setOpacity(0.0, at: videoAsset.duration)
        mainInstruction.layerInstructions = [videoLayerInstruction]
        
        let mainCompositionInst = AVMutableVideoComposition()
        var naturalSize = Self.getSize(videoInputUrl: videoInputUrl)
        if naturalSize.width == 0 || naturalSize.height == 0 {
            completionHandler(false, nil)
            return
        }
        let renderWidth = naturalSize.width
        let renderHeight = naturalSize.height
        mainCompositionInst.renderSize = CGSize(width: renderWidth, height: renderHeight)
        mainCompositionInst.instructions = [mainInstruction]
        mainCompositionInst.frameDuration = CMTimeMake(value: 1, timescale: 13)
        
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(x: 0, y: 0, width: naturalSize.width, height: naturalSize.height)
        videoLayer.frame = CGRect(x: 0, y: 0, width: naturalSize.width, height: naturalSize.height)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)
        mainCompositionInst.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        
        let session = JFAVAssetExportSession(asset: mixComposition)
        
        if let outPutFilePath = outPutFilePath {
            session.outputURL = URL(fileURLWithPath: outPutFilePath)
        } else {
            session.outputURL = URL(fileURLWithPath: videoInputUrl.path)
        }
        
        if let url = session.outputURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        
        session.videoComposition = mainCompositionInst
        
        session.progressHandle = { progress in
            DispatchQueue.main.async {
                progressHandler?(CGFloat(progress))
            }
        }
        
        session.exportAsynchronously {
            let success = session.status == .completed
            DispatchQueue.main.async {
                if success {
                    if let url = session.outputURL, FileManager.default.fileExists(atPath: url.path) {
                        completionHandler(true, session.outputURL)
                    } else {
                        completionHandler(false, nil)
                    }
                } else {
                    print(session.error ?? "")
                    completionHandler(false, nil)
                }
            }
        }
    }
    
    class func getSize(videoInputUrl: URL) -> CGSize {
        // 1. Create AVAsset instance
        let videoAsset = AVAsset(url: videoInputUrl)
        // 2. Track of the asset
        guard let videoAssetTrack = videoAsset.tracks(withMediaType: .video).first else {
            return CGSize.zero
        }
        // 2.1 Size of the asset
        let naturalSize = videoAssetTrack.naturalSize
        return naturalSize
    }
}
