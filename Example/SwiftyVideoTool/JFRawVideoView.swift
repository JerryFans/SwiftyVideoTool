//
//  JFRawVideoView.swift
//  App
//
//  Created by JerryFans on 2023/9/11.
//

import UIKit
import AVFoundation

@objc enum JFVideoPlayerState: Int {
    case unkonw
    case playing
    case pause
    case stop
    case buffering
    case failed
}

protocol JFRawVideoViewDelegate: NSObjectProtocol {
    func videoViewReadyToPlay(playerItem: AVPlayerItem, view: JFRawVideoView)
    func videoViewPlayerPlayingProgress(currentTime: Double, totalTime: Double, view: JFRawVideoView)
    func videoViewPlayerStatusDidChange(state: JFVideoPlayerState, view: JFRawVideoView)
    func videoViewPlayerDidPlayToEnd(noti: Notification, view: JFRawVideoView)
}

extension JFRawVideoViewDelegate {
    func videoViewReadyToPlay(playerItem: AVPlayerItem, view: JFRawVideoView) {
        
    }
    
    func videoViewPlayerPlayingProgress(currentTime: Double, totalTime: Double, view: JFRawVideoView) {
        
    }
    
    func videoViewPlayerStatusDidChange(state: JFVideoPlayerState, view: JFRawVideoView) {
        
    }
    
    func videoViewPlayerDidPlayToEnd(noti: Notification, view: JFRawVideoView) {
        
    }
}

@objcMembers
class JFRawVideoView: JFPlayerView {
    
    var playId: String = UUID().uuidString.lowercased()
    var clickPlayTs = Date().timeIntervalSince1970
    
    var seekTime: CMTime? = nil
    var isFadeToDisplay: Bool = false
    
    var player: AVPlayer? { playerLayer.player }
    
    var playerItem: AVPlayerItem? {
        willSet {
            guard let oldItem = playerItem else { return }
            if let newItem = newValue, newItem == oldItem { return }
            
            NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: oldItem)
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
            oldItem.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            oldItem.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        }
        didSet {
            guard let newItem = playerItem else { return }
            if let oldItem = oldValue, newItem == oldItem { return }
            
            NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidPlayToEnd(noti:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: newItem)
            newItem.addObserver(self, forKeyPath: "status", options: .new, context: nil)
            newItem.addObserver(self, forKeyPath: "loadedTimeRanges", options: .new, context: nil)
            newItem.addObserver(self, forKeyPath: "playbackBufferEmpty", options: .new, context: nil)
            newItem.addObserver(self, forKeyPath: "playbackLikelyToKeepUp", options: .new, context: nil)
        }
    }
    
    var playbackTimeObserver: NSObject?
    var videoURL: URL?
    //兼容直接从相册拉取PlayerItem播放视频
    var originPlayerItem: AVPlayerItem?
    var state: JFVideoPlayerState = .unkonw {
        didSet {
            if oldValue == state {
                return
            }
            switch state {
            case .playing, .buffering:
                //新版SLog播放时，需把挂起的房间暂停
                break
            case .unkonw, .failed, .pause, .stop:
                break
            }
            
            self.stateDidChanged()
            self.deletgate?.videoViewPlayerStatusDidChange(state: state, view: self)
        }
    }
    weak var deletgate: JFRawVideoViewDelegate?
    var isPauseByUser: Bool = true
    var totalTime: Double = 0
    var currentTime: Double = 0
    var playTime: Double {
        get {
            return self.totalTime - self.currentTime
        }
    }
    var repeatCount: Int = 0 //重复播放次数
    
    var didEnterBackground = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.backgroundColor = .black
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: NSNotification.Name(rawValue: UIApplication.willResignActiveNotification.rawValue), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterPlayGround), name: NSNotification.Name(rawValue: UIApplication.didBecomeActiveNotification.rawValue), object: nil)
        
        self.playerLayer.videoGravity = .resizeAspectFill //resizeAspect
        self.playerLayer.addObserver(self, forKeyPath: "readyForDisplay", options: .new, context: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        self.player?.currentItem?.cancelPendingSeeks()
        self.player?.currentItem?.asset.cancelLoading()
        self.player?.pause()
        
        if let playbackObserver = self.playbackTimeObserver {
            self.player?.removeTimeObserver(playbackObserver)
            self.playbackTimeObserver = nil
        }
        
        //解决旧系统 不走willSet 导致kvo 没移除崩溃
        if self.playerItem != nil {
            self.playerItem?.removeObserver(self, forKeyPath: "status")
            self.playerItem?.removeObserver(self, forKeyPath: "loadedTimeRanges")
            self.playerItem?.removeObserver(self, forKeyPath: "playbackBufferEmpty")
            self.playerItem?.removeObserver(self, forKeyPath: "playbackLikelyToKeepUp")
        }
        
        self.playerLayer.removeObserver(self, forKeyPath: "readyForDisplay")
        
        print("video view dealloc")
    }
    
    func setUpPlayer() {
        guard self.videoURL != nil || self.originPlayerItem != nil else {
            return
        }
        if let url = self.videoURL {
            let asset = AVURLAsset(url: url)
            self.playerItem = AVPlayerItem(asset: asset)
        } else if let originItem = self.originPlayerItem {
            self.playerItem = originItem
        }
        let player = AVPlayer(playerItem: self.playerItem!)
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.player = player
        
        self.monitoringPlayback(playerItem: self.playerItem)
        self.isPauseByUser = false
    }
    
    func monitoringPlayback(playerItem: AVPlayerItem?) {
        if playerItem != nil, let player = self.player {
            self.playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: nil) { [weak self] (time) in
                guard let sself = self, let item = sself.playerItem else {
                    return
                }
                guard item.duration.timescale != 0 else {
                    return
                }
                guard item.currentTime().timescale != 0 else {
                    return
                }
                sself.totalTime = Double(item.duration.value / Int64(item.duration.timescale))
                sself.currentTime = Double(time.value / Int64(time.timescale))
                if sself.deletgate != nil {
                    sself.deletgate?.videoViewPlayerPlayingProgress(currentTime: sself.currentTime, totalTime: sself.totalTime, view: sself)
                }
//                print("video playing current time : \(sself.currentTime), total time : \(sself.totalTime)")
            } as? NSObject
        }
    }
    
    func resetPlayer() {
        self.didEnterBackground = false
        if self.playbackTimeObserver != nil {
            self.player?.removeTimeObserver(self.playbackTimeObserver!)
            self.playbackTimeObserver = nil
        }
        self.pauseVideo()
        self.player?.currentItem?.cancelPendingSeeks()
        self.player?.currentItem?.asset.cancelLoading()
        self.player?.replaceCurrentItem(with: nil)
        self.playerItem = nil
        self.state = .stop
    }
    
//    override func layoutSubviews() {
//        super.layoutSubviews()
//        if self.size != CGSize.zero {
//            self.playerLayer?.frame = self.bounds
//        }
//    }
    
    func playVideo() {
        if state == .pause || self.repeatCount > 0 {
            self.state = .playing
        } else {
            self.state = .buffering
        }
        if self.player == nil {
            self.setUpPlayer()
        }
        self.pauseBackgroundSound()
        self.clickPlayTs = Date().timeIntervalSince1970
        self.player?.play()
        print("play url : \(self.videoURL?.absoluteString ?? "url is null")")
    }
    
    func pauseVideo() {
        self.player?.pause()
        self.state = .pause
    }
    
    func seekToTime(dragSeconds: Float) {
        let seconds: Int = Int(Double(dragSeconds) * self.totalTime)
        self.player?.seek(to: CMTime(value: CMTimeValue(seconds), timescale: 1), toleranceBefore: CMTime(value: 1, timescale: 1), toleranceAfter: CMTime(value: 1, timescale: 1), completionHandler: { (finished) in
            
        })
    }
    
    @objc func playerItemDidPlayToEnd(noti: Notification) {
        self.didPlayToEnd()
        self.repeatCount += 1
        self.resumeBackgroundSound()
        let time = CMTime(value: CMTimeValue(0.2), timescale: 1)
        self.player?.seek(to: time)
        self.pauseVideo()
        self.deletgate?.videoViewPlayerDidPlayToEnd(noti: noti, view: self)
    }
    
    func resumeBackgroundSound() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            
        }
    }
    
    func pauseBackgroundSound() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            
        }
    }
    
    // 给子类实现的方法
    func stateDidChanged() {}
    func didPlayToEnd() {}
    
}

// MARK: 播放状态监听 observer
extension JFRawVideoView {
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let key = keyPath else { return }
        guard let player = self.player else { return }
        guard let playerItem = self.playerItem else { return }
        
        switch key {
        
        case "status":
            switch playerItem.status {
            case .readyToPlay:
                print("video view status AVPlayerStatusReadyToPlay")
                
                if frame.size == .zero {
                    setNeedsLayout()
                    layoutIfNeeded()
                }
                
                // 跳到xx秒播放视频
                if let seekTime = self.seekTime {
                    self.seekTime = nil
                    player.seek(to: seekTime)
                }
                self.state = .playing
                let time = Date().timeIntervalSince1970 - self.clickPlayTs
                deletgate?.videoViewReadyToPlay(playerItem: playerItem, view: self)
                
            case .failed:
                self.resetPlayer()
                self.state = .failed
            case .unknown:
                self.resetPlayer()
                self.state = .failed
                
            default:
                break
            }
            
            
        case "loadedTimeRanges": // TODO 缓冲
            
            guard let playerItem = player.currentItem else {
                print("video view status playerItem is nil")
                return
            }
            guard let lastTimeRange = playerItem.loadedTimeRanges.last?.timeRangeValue else {
                print("video view status loadedTimeRanges is empty")
                return
            }
            let bufferEndTime = CMTimeGetSeconds(lastTimeRange.end)
            let currentTime = CMTimeGetSeconds(player.currentTime())
            if bufferEndTime <= currentTime && (currentTime > 0 && bufferEndTime > 0) {
                print("video view status loadedTimeRanges: buffering bufferTime: \(bufferEndTime) currentTime: \(currentTime)")
                state = .buffering
            } else {
                print("video view status loadedTimeRanges: buffer is enough for playing bufferTime: \(bufferEndTime) currentTime: \(currentTime)")
                if state == .buffering && bufferEndTime - currentTime > 3 {
                    playVideo()
                    state = .playing
                }
            }
            break
            
            
        case "playbackBufferEmpty":
            // 当缓冲是空的时候
            print("video view status playbackBufferEmpty 缓冲中")
            if playerItem.isPlaybackBufferEmpty {
                state = .buffering
            }
            
            
        case "playbackLikelyToKeepUp":
            // 当缓冲好的时候
            print("video view status playbackLikelyToKeepUp")
            if (playerItem.isPlaybackBufferFull || playerItem.isPlaybackLikelyToKeepUp), state == .buffering {
                playVideo()
            }
            
            
        case "readyForDisplay":
            guard playerLayer.isReadyForDisplay, self.alpha == 0 else { return }
            if isFadeToDisplay {
                UIView.animate(withDuration: 0.22) { self.alpha = 1 }
            } else {
                self.alpha = 1
            }
            
            
        default:
            break
        }
    }
    
    @objc func appDidEnterBackground() {
//        self.player?.replaceCurrentItem(with: nil)
        switch self.state {
        case .playing:
            self.pauseVideo()
            self.isPauseByUser = false
            break
        case .buffering:
            self.isPauseByUser = true
            break
        default:
            self.isPauseByUser = true
        }
        self.didEnterBackground = true
    }
    
    @objc func appDidEnterPlayGround()  {
//        self.player?.replaceCurrentItem(with: self.playerItem)
        if self.isPauseByUser == false {
            self.playVideo()
        }
        self.didEnterBackground = false
    }
    
}

extension JFRawVideoView {
    func replaceVideoURL(_ videoURL: URL?, seekTime: CMTime? = nil) {
        
        self.pauseVideo()
        self.isPauseByUser = false
        self.totalTime = 0
        self.currentTime = 0
        self.repeatCount = 0
        self.playId = UUID().uuidString.lowercased()
        self.state = .stop
        
        self.videoURL = nil
        self.playerItem = nil
        if let observer = self.playbackTimeObserver {
            self.player?.removeTimeObserver(observer)
            self.playbackTimeObserver = nil
        }
        
        self.player?.currentItem?.cancelPendingSeeks()
        self.player?.currentItem?.asset.cancelLoading()
        
        guard let obURL = videoURL else {
            self.state = .stop
            self.seekTime = nil
            self.player?.replaceCurrentItem(with: nil)
            return
        }
        
        self.seekTime = seekTime
        
        let player = self.player ?? {
            let player = AVPlayer()
            player.automaticallyWaitsToMinimizeStalling = false
            playerLayer.player = player
            return player
        }()
        
        let asset = AVURLAsset(url: obURL)
        let playerItem = AVPlayerItem(asset: asset)
        
        self.videoURL = videoURL
        self.playerItem = playerItem
        self.monitoringPlayback(playerItem: playerItem)
        
        player.replaceCurrentItem(with: playerItem)
    }
}
