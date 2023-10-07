//
//  JFPlayerView.swift
//  App
//
//  Created by JerryFans on 2023/9/11.
//

import UIKit
import AVFoundation

class JFPlayerView: UIView {
    // MARK: - 重写的父类函数
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
