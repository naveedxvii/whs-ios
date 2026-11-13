import UIKit
import AVFoundation

/// Camera screen for barcodes and QR codes.
/// Front or rear camera, continuous autofocus, tap to focus, and zoom (pinch or 1x / 2x / 4x).
final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var types: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
    var continuous = false

    private let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var input: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var finished = false
    private var pinchStart: CGFloat = 1
    private let maxZoom: CGFloat = 6

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer

        session.beginConfiguration()
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = types.filter { output.availableMetadataObjectTypes.contains($0) }
        configureInput()
        session.commitConfiguration()

        addSwitchButton()
        addZoomButtons()
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapToFocus(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        finished = false
        let s = session
        DispatchQueue.global().async { s.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        DispatchQueue.global().async { s.stopRunning() }
    }

    // MARK: - Camera

    /// Swaps in the camera for `position`. Call inside session.beginConfiguration().
    private func configureInput() {
        if let old = input {
            session.removeInput(old)
            input = nil
        }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        guard let device,
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return }
        session.addInput(newInput)
        input = newInput
        enableAutoFocus(device)
        setZoom(1)
    }

    private func enableAutoFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // If the camera can't be locked, it keeps its default focus.
        }
    }

    private var currentZoom: CGFloat {
        input?.device.videoZoomFactor ?? 1
    }

    private func setZoom(_ factor: CGFloat) {
        guard let device = input?.device else { return }
        let limit = min(device.activeFormat.videoMaxZoomFactor, maxZoom)
        let zoom = min(max(factor, 1), limit)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = zoom
            device.unlockForConfiguration()
        } catch {
            // Zoom is not available on this camera.
        }
    }

    @objc private func switchCamera() {
        position = position == .back ? .front : .back
        session.beginConfiguration()
        configureInput()
        session.commitConfiguration()
    }

    @objc private func zoomTapped(_ button: UIButton) {
        setZoom(CGFloat(button.tag))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStart = currentZoom
        }
        if gesture.state == .changed {
            setZoom(pinchStart * gesture.scale)
        }
    }

    @objc private func tapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let device = input?.device, let layer = previewLayer else { return }
        let point = layer.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view))
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
        // Return to continuous autofocus after the tap focus settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let device = self?.input?.device { self?.enableAutoFocus(device) }
        }
    }

    // MARK: - Buttons

    private func addSwitchButton() {
        let button = roundButton(systemName: "camera.rotate.fill")
        button.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func addZoomButtons() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for level in [1, 2, 4] {
            let button = UIButton(type: .system)
            button.setTitle("\(level)x", for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .boldSystemFont(ofSize: 15)
            button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            button.layer.cornerRadius = 16
            button.tag = level
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTarget(self, action: #selector(zoomTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
    }

    private func roundButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Results

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !finished,
              let code = metadataObjects
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first?.stringValue else { return }
        if !continuous { finished = true }
        onCode?(code)
    }
}
