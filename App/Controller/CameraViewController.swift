//
//  ViewController.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/20/25.
//

import AVFoundation
import PhotosUI
import UIKit

class CameraViewController: UIViewController {
    
    private var cameraController: CameraController!
    
    private var selection = [String: PHPickerResult]()
    private var selectedAssetIdentifiers = [String]()
    private var selectedAssetIdentifierIterator: IndexingIterator<[String]>?
    private var currentAssetIdentifier: String?
    
    private lazy var cameraPreview: CameraPreview = {
        let preview = CameraPreview(frame: self.view.frame)
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
        
        self.cameraController = CameraController(cameraProcessor: CameraVirtualBackgroundProcessor())
        self.cameraController.fpsDelegate = self
        
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
        
        self.view.addSubview(imagePickerButton)
        
        NSLayoutConstraint.activate([
            imagePickerButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            view.trailingAnchor.constraint(equalTo: imagePickerButton.trailingAnchor, constant: 15)
        ])
        
        self.view.addSubview(fpsLabel)
        
        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            fpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15)
        ])
        
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
    
    private func presentPicker(filter: PHPickerFilter?) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        
        // Set the filter type according to the user’s selection.
        configuration.filter = filter
        // Set the mode to avoid transcoding, if possible, if your app supports arbitrary image/video encodings.
        configuration.preferredAssetRepresentationMode = .current
        // Set the selection behavior to respect the user’s selection order.
        configuration.selection = .ordered
        // Set the selection limit to enable multiselection.
        configuration.selectionLimit = 1
        // Set the preselected asset identifiers with the identifiers that the app tracks.
        configuration.preselectedAssetIdentifiers = selectedAssetIdentifiers
        
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

private extension CameraViewController {
    func displayNext() {
        guard let assetIdentifier = selectedAssetIdentifierIterator?.next() else { return }
        currentAssetIdentifier = assetIdentifier
        
        let itemProvider = selection[assetIdentifier]!.itemProvider
        if itemProvider.canLoadObject(ofClass: UIImage.self) {
            itemProvider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                DispatchQueue.main.async {
                    self?.handleCompletion(assetIdentifier: assetIdentifier, object: image, error: error)
                }
            }
        }
    }
    
    func handleCompletion(assetIdentifier: String, object: Any?, error: Error? = nil) {
        guard currentAssetIdentifier == assetIdentifier else { return }
        if let cgImega = rotateIfNeeded(object as? UIImage)?.cgImage {
            cameraController.setImage(cgImega: cgImega)
        }
    }
}

extension CameraViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        dismiss(animated: true)
        
        let existingSelection = self.selection
        var newSelection = [String: PHPickerResult]()
        for result in results {
            let identifier = result.assetIdentifier!
            newSelection[identifier] = existingSelection[identifier] ?? result
        }
        
        // Track the selection in case the user deselects it later.
        selection = newSelection
        selectedAssetIdentifiers = results.map(\.assetIdentifier!)
        selectedAssetIdentifierIterator = selectedAssetIdentifiers.makeIterator()
        
        if !selection.isEmpty {
            displayNext()
        }
    }
}
