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

protocol FpsDelegate: AnyObject {
    func didUpdateFps(_ fps: Double)
}

class CameraController: NSObject {
    
    enum SessionSetupResult {
        case success
        case failed
    }
    
    private let devicePosition: AVCaptureDevice.Position = .front
    
    private let captureSession = AVCaptureSession()
    
    private let sessionQueue = DispatchQueue(label: "session.queue")
    
    private let dataOutputQueue = DispatchQueue(label: "data.output.queue")
    
    private let cameraVideoDataOutput = AVCaptureVideoDataOutput()
    
    private var videoTrackSourceFormatDescription: CMFormatDescription?
    
    private var cameraDeviceInput: AVCaptureDeviceInput?
    
    private var cameraProcessor: CameraProcessor?
    
    private var setupResult: SessionSetupResult = .success
    
    private var isSessionRunning = false
    
    private var isRenderingEnabled = true
    
    private var lastFpsTimestamp: TimeInterval = CACurrentMediaTime()
    
    private var frameCount = 0
    
    weak var fpsDelegate: FpsDelegate?
    
    weak var cameraPreview: CameraPreview?
    
    init(cameraProcessor: CameraProcessor?) {
        self.cameraProcessor = cameraProcessor
    }
    
    /// Configures the overall camera
    public func configure() {
        configureCaptureSession()
    }
    
    public func startRunning() -> SessionSetupResult {
        if setupResult == .success {
            sessionQueue.async {
                self.captureSession.startRunning()
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
        
        return setupResult
    }
    
    public func stopRunning() {
        if setupResult == .success {
            sessionQueue.async {
                self.captureSession.stopRunning()
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }
    
    public func restartSession() {
        sessionQueue.async {
            if self.isSessionRunning {
                self.captureSession.startRunning()
                self.isSessionRunning = self.captureSession.isRunning
            }
        }
    }
    
    public func enableRendering() {
        dataOutputQueue.async {
            self.isRenderingEnabled = true
        }
    }
    
    public func disableRendering() {
        dataOutputQueue.async {
            self.isRenderingEnabled = false
        }
    }
    
    public func applyBackgroundImage(_ image: CGImage) {
        cameraProcessor?.applyBackgroundImage(image)
    }
}

// MARK: Camera Pipeline Configuration

extension CameraController {
    
    /// Configures the capture session.
    fileprivate func configureCaptureSession() {
        /*
         Configure the capture session.
         In general it is not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         */
        sessionQueue.async {
            self.configureSession()
            self.captureSession.automaticallyConfiguresApplicationAudioSession = false
            self.captureSession.sessionPreset = .hd1280x720
        }
    }
    
    // Must be called on the session queue
    private func configureSession() {
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }
        
        guard configureCamera() else {
            setupResult = .failed
            return
        }
    }
    
    func configureCamera() -> Bool {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: devicePosition) else {
            Log.error("Could not find the camera")
            return false
        }
        
        // Add the camera input to the session
        do {
            if let cameraDeviceInput = self.cameraDeviceInput {
                captureSession.removeInput(cameraDeviceInput)
            }
            
            self.cameraDeviceInput = try AVCaptureDeviceInput(device: camera)
            
            guard let cameraDeviceInput = self.cameraDeviceInput,
                  captureSession.canAddInput(cameraDeviceInput) else {
                Log.error("Could not add camera device input")
                return false
            }
            captureSession.addInputWithNoConnections(cameraDeviceInput)
        } catch {
            Log.error("Could not create camera device input: \(error)")
            return false
        }
        
        // Find the camera device input's video port
        guard let cameraDeviceInput = self.cameraDeviceInput,
              let cameraVideoPort = cameraDeviceInput.ports(for: .video, sourceDeviceType: camera.deviceType,
                                                            sourceDevicePosition: camera.position).first else {
            Log.error("Could not find the camera device input's video port")
            return false
        }
        
        // Add the camera video data output
        guard captureSession.canAddOutput(cameraVideoDataOutput) else {
            Log.error("Could not add the camera video data output")
            return false
        }
        captureSession.addOutputWithNoConnections(cameraVideoDataOutput)
        cameraVideoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        cameraVideoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
        
        // Connect the camera device input to the camera video data output
        let cameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [cameraVideoPort], output: cameraVideoDataOutput)
        guard captureSession.canAddConnection(cameraVideoDataOutputConnection) else {
            Log.error("Could not add a connection to the camera video data output")
            return false
        }
        captureSession.addConnection(cameraVideoDataOutputConnection)
        cameraVideoDataOutputConnection.videoRotationAngle = 90
        cameraVideoDataOutputConnection.automaticallyAdjustsVideoMirroring = false
        cameraVideoDataOutputConnection.isVideoMirrored = true
        
        return true
    }
}

// MARK: Camera Capture Delegates

extension CameraController: AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentTime = CACurrentMediaTime()
        let elapsedTime = currentTime - lastFpsTimestamp
        
        frameCount += 1
        
        if elapsedTime >= 1.0 { // Update FPS every second
            let fps = Double(frameCount) / elapsedTime
            
            fpsDelegate?.didUpdateFps(fps)
            
            frameCount = 0
            lastFpsTimestamp = currentTime
        }
        
        if let videoDataOutput = output as? AVCaptureVideoDataOutput {
            processVideoSampleBuffer(sampleBuffer, fromOutput: videoDataOutput)
        }
    }
    
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, fromOutput videoDataOutput: AVCaptureVideoDataOutput) {
        guard isRenderingEnabled else {
            return
        }
        
        if videoTrackSourceFormatDescription == nil {
            videoTrackSourceFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        }
        
        if videoDataOutput == cameraVideoDataOutput {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            
            guard let pixelBuffer = cameraProcessor?.process(imageBuffer) else {
                return
            }
            
            cameraPreview?.pixelBuffer = pixelBuffer
        }
    }
}
