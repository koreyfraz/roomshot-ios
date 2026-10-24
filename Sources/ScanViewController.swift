import UIKit
import ARKit
import SceneKit
import simd

/// Live LiDAR room scan using ARKit scene reconstruction.
/// On Done, writes the room surfaces (furniture removed) as raw triangles for the page to process.
final class ScanViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    var onFinish: ((Int) -> Void)?

    private let sceneView = ARSCNView()
    private let statusLabel = PaddedLabel()
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var lastStatusTime: TimeInterval = 0
    private var finished = false

    private let accent = UIColor(red: 0.88, green: 0.21, blue: 0.17, alpha: 1)
    private lazy var meshMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents = accent.withAlphaComponent(0.85)
        m.fillMode = .lines
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        _ = meshMaterial // build it on the main thread before the renderer uses it

        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = false
        view.addSubview(sceneView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.layer.cornerRadius = 12
        statusLabel.clipsToBounds = true
        statusLabel.text = "Walk the room slowly. Cover every wall, sweep the whole ceiling, then the floor edges."
        view.addSubview(statusLabel)

        style(doneButton, title: "Done", background: accent)
        style(cancelButton, title: "Cancel", background: UIColor.black.withAlphaComponent(0.6))
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

            cancelButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            cancelButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            cancelButton.widthAnchor.constraint(equalToConstant: 110),
            cancelButton.heightAnchor.constraint(equalToConstant: 54),

            doneButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            doneButton.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            doneButton.heightAnchor.constraint(equalToConstant: 54),
        ])
    }

    private func style(_ button: UIButton, title: String, background: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.backgroundColor = background
        button.layer.cornerRadius = 14
        view.addSubview(button)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            statusLabel.text = "This iPhone doesn't have a LiDAR scanner."
            doneButton.isEnabled = false
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .meshWithClassification
        config.planeDetection = []
        config.environmentTexturing = .none
        UIApplication.shared.isIdleTimerDisabled = true
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Live mesh overlay

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        return SCNNode(geometry: makeGeometry(mesh.geometry))
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = makeGeometry(mesh.geometry)
    }

    private func makeGeometry(_ g: ARMeshGeometry) -> SCNGeometry {
        let v = g.vertices
        let vertexData = Data(bytes: v.buffer.contents().advanced(by: v.offset), count: v.stride * v.count)
        let source = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: v.count,
                                       usesFloatComponents: true, componentsPerVector: 3,
                                       bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: v.stride)
        let f = g.faces
        let faceData = Data(bytes: f.buffer.contents(), count: f.bytesPerIndex * f.indexCountPerPrimitive * f.count)
        let element = SCNGeometryElement(data: faceData, primitiveType: .triangles,
                                         primitiveCount: f.count, bytesPerIndex: f.bytesPerIndex)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [meshMaterial]
        return geometry
    }

    // MARK: - Status

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastStatusTime > 1, !finished else { return }
        lastStatusTime = frame.timestamp
        var message: String
        switch frame.camera.trackingState {
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: message = "Slow down a little."
            case .insufficientFeatures: message = "Aim at walls or objects with more detail."
            default: message = "Hold steady while tracking starts…"
            }
        case .notAvailable:
            message = "Tracking unavailable."
        case .normal:
            let faces = frame.anchors.reduce(0) { total, anchor in
                total + ((anchor as? ARMeshAnchor)?.geometry.faces.count ?? 0)
            }
            message = "\(faces / 1000)k surfaces. Get every wall, the whole ceiling and the floor edges, then tap Done."
        }
        statusLabel.text = message
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        statusLabel.text = "Scan stopped: \(error.localizedDescription)"
    }

    // MARK: - Finish

    @objc private func cancelTapped() {
        finish(0)
    }

    @objc private func doneTapped() {
        guard let frame = sceneView.session.currentFrame else { finish(0); return }
        doneButton.isEnabled = false
        statusLabel.text = "Saving scan…"
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        sceneView.session.pause()
        DispatchQueue.global(qos: .userInitiated).async {
            let count = ScanViewController.export(anchors)
            DispatchQueue.main.async { self.finish(count) }
        }
    }

    private func finish(_ count: Int) {
        guard !finished else { return }
        finished = true
        UIApplication.shared.isIdleTimerDisabled = false
        onFinish?(count)
    }

    /// Writes world-space triangles (Float32 x,y,z ×3 per face, Y up) to the scan file.
    /// Drops faces ARKit classifies as tables or seats, and makes floor faces point up and ceiling faces point down.
    static func export(_ anchors: [ARMeshAnchor]) -> Int {
        let total = anchors.reduce(0) { $0 + $1.geometry.faces.count }
        var out = [Float]()
        out.reserveCapacity(total * 9)
        var triangles = 0

        for anchor in anchors {
            let g = anchor.geometry
            let transform = anchor.transform
            let vBase = g.vertices.buffer.contents()
            let vOffset = g.vertices.offset
            let vStride = g.vertices.stride
            let fBase = g.faces.buffer.contents()
            let bytesPerIndex = g.faces.bytesPerIndex
            let classes = g.classification

            func vertex(_ i: Int) -> SIMD3<Float> {
                let p = vBase.advanced(by: vOffset + vStride * i)
                let x = p.load(fromByteOffset: 0, as: Float.self)
                let y = p.load(fromByteOffset: 4, as: Float.self)
                let z = p.load(fromByteOffset: 8, as: Float.self)
                let w = transform * SIMD4<Float>(x, y, z, 1)
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            func index(_ face: Int, _ corner: Int) -> Int {
                let offset = (face * 3 + corner) * bytesPerIndex
                if bytesPerIndex == 4 { return Int(fBase.load(fromByteOffset: offset, as: UInt32.self)) }
                return Int(fBase.load(fromByteOffset: offset, as: UInt16.self))
            }

            for face in 0..<g.faces.count {
                var kind: UInt8 = 0
                if let c = classes {
                    kind = c.buffer.contents().load(fromByteOffset: c.offset + c.stride * face, as: UInt8.self)
                }
                // ARMeshClassification: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door
                if kind == 4 || kind == 5 { continue }

                let a = vertex(index(face, 0))
                var b = vertex(index(face, 1))
                var c = vertex(index(face, 2))
                let normal = simd_cross(b - a, c - a)
                if (kind == 2 && normal.y < 0) || (kind == 3 && normal.y > 0) {
                    swap(&b, &c)
                }
                out.append(contentsOf: [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
                triangles += 1
            }
        }

        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: AppSchemeHandler.scanURL, options: .atomic)
        } catch {
            return 0
        }
        return triangles
    }
}

/// UILabel with inner padding for the status pill.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
