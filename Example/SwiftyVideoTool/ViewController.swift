//
//  ViewController.swift
//  SwiftyVideoTool
//
//  Created by JerryFans on 10/02/2023.
//  Copyright (c) 2023 JerryFans. All rights reserved.
//

import UIKit
import SnapKit
import JFPopup
import JRBaseKit
import SwiftyVideoTool

class ViewController: UIViewController {
    
    lazy var videoView: JFRawVideoView = {
        let view = JFRawVideoView(frame: .zero)
        view.backgroundColor = .black
        return view
    }()
    
    lazy var addWaterMarkBtn: UIButton = {
        let btn = UIButton(type: .custom)
        btn.addTarget(self, action: #selector(addWaterMarkBtnClick), for: .touchUpInside)
        btn.setTitle("Add Water Mark", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor.blue
        btn.layer.cornerRadius = 12
        btn.layer.masksToBounds = true
        return btn
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.addSubview(self.videoView)
        let width = UIScreen.main.bounds.size.width > 600 ? 600 : UIScreen.main.bounds.size.width
        let height = width * 4 / 3
        self.videoView.frame = CGRect(x: 0, y: 88, width: width, height: height)
        self.videoView.jf.centerX = self.view.jf.centerX
        if let urlStr = Bundle.main.path(forResource: "testVideo", ofType: "mp4", inDirectory: "Resouces")  {
            let url = URL(fileURLWithPath: urlStr)
            self.videoView.videoURL = url
            self.videoView.playVideo()
        }
        
        self.view.addSubview(self.addWaterMarkBtn)
        self.addWaterMarkBtn.snp.makeConstraints { make in
            make.right.equalTo(-15)
            make.top.equalTo(self.videoView.snp.bottom).offset(15)
            make.size.equalTo(CGSize(width: 150, height: 44))
        }
    
        // Do any additional setup after loading the view, typically from a nib.
    }
    
    @objc func addWaterMarkBtnClick() {
        JFPopup.loading()
        if let urlStr = Bundle.main.path(forResource: "testVideo", ofType: "mp4", inDirectory: "Resouces")  {
            let url = URL(fileURLWithPath: urlStr)
            let cachePath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0] as String
            let outputPath = cachePath + "/test.mp4"
            
            JFVideoTool.addtWatermark(videoInputUrl: url, outPutFilePath: outputPath) {
                let label = UILabel()
                label.text = "Designed By JerryFans"
                label.textColor = .white
                label.font = UIFont.systemFont(ofSize: 30, weight: .semibold)
                label.sizeToFit()
                label.layer.shadowOffset = .init(width: 1.5, height: 1.5)
                label.layer.shadowColor = UIColor.jf.rgb(0x000000, alpha: 1).cgColor
                label.layer.shadowOpacity = 0.8
                label.layer.shadowRadius = 1.5
                return (label,.bottomRight(bottom: 15, right: 15))
            } progressHandler: { progress in
                print("handle progress \(progress)")
            } completionHandler: { [weak self] isSuc, url in
                if isSuc, let url {
                    JFPopup.hideLoading()
                    JFPopup.toast(hit: "添加水印成功", icon: .success)
                    self?.videoView.pauseVideo()
                    self?.videoView.replaceVideoURL(url)
                    self?.videoView.playVideo()
                }
            }

        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

}

