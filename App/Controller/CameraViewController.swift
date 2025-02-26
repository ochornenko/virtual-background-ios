//
//  ViewController.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/20/25.
//

import AVFoundation
import UIKit

class CameraViewController: UIViewController {
    
    private var cameraController: CameraController!
    
    private lazy var cameraPreview: CameraPreview = {
        let preview = CameraPreview(frame: self.view.frame)
        preview.translatesAutoresizingMaskIntoConstraints = false
        return preview
    }()
    
    private lazy var cameraUnavailableLabel: UILabel = {
        let label = UILabel()
        label.text = "Camera Unavailable"
        label.textColor = .white
        label.textAlignment = .left
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.cameraController = CameraController(cameraProcessor: CameraVirtualBackgroundProcessor())
        
        setup()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        requestCameraPermission { granted in
            if granted {
                self.cameraController.configure()
                
                switch self.cameraController.startRunning() {
                case .success:
                    self.addObservers()
                case .failed:
                    self.showCameraDisabledAlert()
                }
            } else {
                self.showCameraDisabledAlert()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        cameraController.stopRunning()
        removeObservers()
        super.viewWillDisappear(animated)
    }
    
    private func setup() {
        self.view.addSubview(cameraPreview)
        
        NSLayoutConstraint.activate([
            cameraPreview.topAnchor.constraint(equalTo: view.topAnchor),
            cameraPreview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cameraPreview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraPreview.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        cameraController.cameraPreview = cameraPreview
        
        self.view.addSubview(cameraUnavailableLabel)
        
        cameraUnavailableLabel.centerXAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerXAnchor).isActive = true
        cameraUnavailableLabel.centerYAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerYAnchor).isActive = true
    }
    
    private func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    private func showCameraDisabledAlert() {
        DispatchQueue.main.async {
            let changePrivacySetting = "This Feature Requires Camera Access. In the Settings turn on Camera Access."
            let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
            let alertController = UIAlertController(title: "Virtual Background", message: message, preferredStyle: .alert)
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                    style: .cancel,
                                                    handler: nil))
            
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                    style: .`default`,
                                                    handler: { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
                }
            }))
            
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    @objc
    private func didEnterBackground(notification: NSNotification) {
        cameraController.disableRendering()
    }
    
    @objc
    private func willEnterForeground(notification: NSNotification) {
        cameraController.enableRendering()
    }
    
    @objc
    private func sessionWasInterrupted(notification: NSNotification) {
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
           let reasonIntegerValue = userInfoValue.integerValue,
           let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            if reason == .videoDeviceInUseByAnotherClient {
                Log.error("Camera is in use by another client")
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                Log.error("Camera unavailable")
            }
        }
    }
    
    @objc
    private func sessionInterruptionEnded(notification: NSNotification) {
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25, animations: {
                self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            })
        }
    }
    
    @objc
    private func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        Log.error("Capture session runtime error: \(error)")
        
        /*
         Automatically try to restart the session running if media services were reset and the last start running succeeded.
         Otherwise, enable the user to try to resume the session running.
         */
        if error.code == .mediaServicesWereReset {
            cameraController.restartSession()
        }
    }
    
    // MARK: Notifications
    private func addObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError),
                                               name: AVCaptureSession.runtimeErrorNotification,
                                               object: nil)
        
        // A session can run only when the app is full screen. It will be interrupted in a multi-app layout.
        // Add observers to handle these session interruptions and inform the user.
        // See AVCaptureSessionWasInterruptedNotification for other interruption reasons.
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted),
                                               name: AVCaptureSession.wasInterruptedNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded),
                                               name: AVCaptureSession.interruptionEndedNotification,
                                               object: nil)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }
}
