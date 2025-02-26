//
//  CameraController.swift
//  VirtualBackground
//
//  Created by Oleg Chornenko on 2/21/25.
//

import AVFoundation

class CameraController: NSObject {
    
    enum SessionSetupResult {
        case success
        case failed
    }
    
    weak var cameraPreview: CameraPreview?
    
    private let devicePosition: AVCaptureDevice.Position = .front
    
    private let captureSession = AVCaptureSession()
    
    private let sessionQueue = DispatchQueue(label: "Session.Queue")
    
    private let dataOutputQueue = DispatchQueue(label: "Data.Output.Queue")
    
    private let cameraVideoDataOutput = AVCaptureVideoDataOutput()
    
    private var setupResult: SessionSetupResult = .success
    
    private var isSessionRunning = false
    
    private var renderingEnabled = true
    
    private var videoTrackSourceFormatDescription: CMFormatDescription?
    
    private(set) var cameraDeviceInput: AVCaptureDeviceInput?
    
    private var cameraProcessor: CameraProcessor?
    
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
            self.renderingEnabled = true
        }
    }
    
    public func disableRendering() {
        dataOutputQueue.async {
            self.renderingEnabled = false
        }
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
         
         Don't do this on the main queue, because AVCaptureMultiCamSession.startRunning()
         is a blocking call, which can take a long time. Dispatch session setup
         to the sessionQueue so as not to block the main queue, which keeps the UI responsive.
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
        dataOutputQueue.async {
            if let videoDataOutput = output as? AVCaptureVideoDataOutput {
                self.processVideoSampleBuffer(sampleBuffer, fromOutput: videoDataOutput)
            }
        }
    }
    
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, fromOutput videoDataOutput: AVCaptureVideoDataOutput) {
        guard renderingEnabled else {
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
