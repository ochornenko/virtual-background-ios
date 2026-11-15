// Copyright 2025 Oleg Chornenko.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFoundation
import PhotosUI
import UIKit

class CameraViewController: UIViewController {
    
    private var cameraController: CameraController!
    
    private var selectedAssetIdentifier: String?
    
    private lazy var cameraPreview: CameraPreview = {
        let preview = CameraPreview(frame: view.frame)
        preview.translatesAutoresizingMaskIntoConstraints = false
        return preview
    }()
    
    private lazy var imagePickerButton: UIButton = {
        let button = UIButton(type: .system)
        let image = UIImage(systemName: "photo")
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        button.setImage(image?.withConfiguration(config), for: .normal)
        button.tintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(presentPickerForImages), for: .touchUpInside)
        return button
    }()
    
    private lazy var fpsLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
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
        
        initialize()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        requestCameraPermission { granted in
            guard granted else {
                self.showCameraDisabledAlert()
                return
            }
            
            self.cameraController.configure()
            self.cameraController.startRunning { result in
                switch result {
                case .success:
                    self.addObservers()
                case .failed:
                    self.showCameraUnavailableLabel()
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        cameraController.stopRunning()
        removeObservers()
        super.viewWillDisappear(animated)
    }
    
    private func initialize() {
        cameraController = CameraController(cameraProcessor: CameraVirtualBackgroundProcessor())
        cameraController.fpsDelegate = self
        
        configureView()
    }
    
    private func configureView() {
        view.addSubview(cameraPreview)
        
        NSLayoutConstraint.activate([
            cameraPreview.topAnchor.constraint(equalTo: view.topAnchor),
            cameraPreview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cameraPreview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraPreview.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        cameraController.cameraPreview = cameraPreview
        
        view.addSubview(imagePickerButton)
        
        NSLayoutConstraint.activate([
            imagePickerButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: imagePickerButton.trailingAnchor, constant: 15)
        ])
        
        view.addSubview(fpsLabel)
        
        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            fpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15)
        ])
        
        view.addSubview(cameraUnavailableLabel)
        
        cameraUnavailableLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor).isActive = true
        cameraUnavailableLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor).isActive = true
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
                                                    style: .default,
                                                    handler: { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL, options: [:], completionHandler: nil)
                }
            }))
            
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    private func presentPicker(filter: PHPickerFilter?) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        
        configuration.filter = filter
        // Set the mode to avoid transcoding, if possible, if your app supports arbitrary image/video encodings.
        configuration.preferredAssetRepresentationMode = .current
        configuration.selectionLimit = 1
        // Show the current background as selected when the picker opens.
        configuration.preselectedAssetIdentifiers = selectedAssetIdentifier.map { [$0] } ?? []
        
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
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
            switch reason {
            case .videoDeviceInUseByAnotherClient:
                Log.error("Camera is in use by another client")
                showCameraUnavailableLabel()
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                Log.error("Camera unavailable")
                showCameraUnavailableLabel()
            default:
                break
            }
        }
    }
    
    private func showCameraUnavailableLabel() {
        DispatchQueue.main.async {
            self.cameraUnavailableLabel.alpha = 0
            self.cameraUnavailableLabel.isHidden = false
            UIView.animate(withDuration: 0.25) {
                self.cameraUnavailableLabel.alpha = 1
            }
        }
    }
    
    @objc
    private func sessionInterruptionEnded(notification: NSNotification) {
        DispatchQueue.main.async {
            guard !self.cameraUnavailableLabel.isHidden else {
                return
            }
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
    
    @objc
    private func presentPickerForImages(_ sender: Any) {
        presentPicker(filter: PHPickerFilter.images)
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

// MARK: FPS delegate

extension CameraViewController: FpsDelegate {
    func didUpdateFps(_ fps: Double) {
        DispatchQueue.main.async {
            self.fpsLabel.text = String(format: "FPS: %.2f", fps)
        }
    }
}

extension CameraViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        
        guard let result = results.first, result.itemProvider.canLoadObject(ofClass: UIImage.self) else {
            return
        }
        
        let assetIdentifier = result.assetIdentifier
        selectedAssetIdentifier = assetIdentifier
        
        result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            if let error = error {
                Log.error("Could not load the selected image: \(error)")
            }
            
            DispatchQueue.main.async {
                // A slower load from an earlier pick must not replace a newer background
                guard let self = self, self.selectedAssetIdentifier == assetIdentifier,
                      let image = rotateIfNeeded(object as? UIImage)?.cgImage else {
                    return
                }
                self.cameraController.applyBackgroundImage(image)
            }
        }
    }
}
