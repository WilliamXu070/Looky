import AppKit
import Foundation
import SwiftUI
import SceneKit
import Metal
import QuickLookCore
import simd

enum EdgeSelectionMode: String {
    case fitted
    case connected
}

struct EdgeFitSettings: Equatable {
    var arcToleranceMultiplier: Float = 3.0
    var minimumArcSweepDegrees: Float = 5.0
    var minimumArcCoverage: Float = 0.75
    var arcRansacIterations: Int = 96
    var minimumArcInlierRatio: Float = 0.72
    var arcInlierGapAllowance: Int = 1
    var minimumLineLengthScale: Float = 0.02
    var minimumArcLengthScale: Float = 0.025
    var lineDeviationDegrees: Float = 0
}

/// A simple SwiftUI wrapper around `SCNView` so we can embed SceneKit or Model I/O
/// content inside a SwiftUI hierarchy.
struct SceneKitViewport: NSViewRepresentable {
    /// The scene to show.  When this changes, the view updates.
    var scene: SCNScene?
    var edgeFitSettings: EdgeFitSettings = .init()
    var edgeProbeMode: Bool = false
    var edgeSelectionMode: EdgeSelectionMode = .fitted
    var edgeProbeOutputDirectory: String = "/tmp/quicklook-edge-probe"
    var surfaceProbeMode: Bool = false
    var surfaceProbeOutputDirectory: String = "/tmp/quicklook-surface-probe"
    var edgeProbeModelHint: String = ""
    var edgeDownloadOutputDirectory: String = "/tmp/quicklook-edge-download"
    var onSelectionResult: ((EdgeSelectionDownload?) -> Void)?
    var edgeOnlyMode: Bool = false
    var selectionDebugMode: Bool = false
    var selectionDebugOutputDirectory: String = "/tmp/quicklook-selection-debug"
    var loaderMetadata: [String: String] = [:]
    var topologyHints: ImportedTopologyHints = .empty
    var onSelectionDebugEvent: ((SelectionDebugEvent) -> Void)?
    var onMeasurementStateChanged: ((SelectionMeasurementState) -> Void)?
    var manualSelectionEnabled: Bool = true
    var testDriver: ViewerTestDriver?
    var selectionDriver: ViewerSelectionDriver?

    func makeNSView(context: Context) -> SCNView {
        let scnView = DebugSelectableSCNView()
        NSLog("SceneKitView initialized with edgeSelectionMode=%@", edgeSelectionMode.rawValue)
        scnView.edgeFitSettings = edgeFitSettings
        scnView.edgeProbeMode = edgeProbeMode
        scnView.edgeSelectionMode = edgeSelectionMode
        scnView.edgeProbeOutputDirectory = edgeProbeOutputDirectory
        scnView.surfaceProbeMode = surfaceProbeMode
        scnView.surfaceProbeOutputDirectory = surfaceProbeOutputDirectory
        scnView.edgeProbeModelHint = edgeProbeModelHint
        scnView.edgeDownloadOutputDirectory = edgeDownloadOutputDirectory
        scnView.onSelectionResult = onSelectionResult
        scnView.edgeOnlyMode = edgeOnlyMode
        scnView.selectionDebugMode = selectionDebugMode
        scnView.selectionDebugOutputDirectory = selectionDebugOutputDirectory
        scnView.loaderMetadata = loaderMetadata
        scnView.importedTopologyHints = topologyHints
        scnView.onSelectionDebugEvent = onSelectionDebugEvent
        scnView.onMeasurementStateChanged = onMeasurementStateChanged
        scnView.manualSelectionEnabled = manualSelectionEnabled
        testDriver?.bind(to: scnView)
        selectionDriver?.bind(to: scnView)
        scnView.allowsCameraControl = true
        scnView.autoresizingMask = [.width, .height]
        scnView.backgroundColor = .clear
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false // we set lighting in the scene builder
        scnView.delegate = scnView
        scnView.isPlaying = true
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        let sceneChanged: Bool
        switch (nsView.scene, scene) {
        case let (current?, next?):
            sceneChanged = current !== next
        case (nil, nil):
            sceneChanged = false
        default:
            sceneChanged = true
        }

        if sceneChanged {
            nsView.scene = scene
            nsView.pointOfView = scene?.rootNode.childNode(withName: "camera", recursively: true)
        }
        if let selectableView = nsView as? DebugSelectableSCNView {
            if sceneChanged {
                selectableView.invalidateSelectionCaches()
            }
            selectableView.edgeFitSettings = edgeFitSettings
            selectableView.edgeProbeMode = edgeProbeMode
            selectableView.edgeSelectionMode = edgeSelectionMode
            selectableView.edgeProbeOutputDirectory = edgeProbeOutputDirectory
            selectableView.surfaceProbeMode = surfaceProbeMode
            selectableView.surfaceProbeOutputDirectory = surfaceProbeOutputDirectory
            selectableView.edgeProbeModelHint = edgeProbeModelHint
            selectableView.edgeDownloadOutputDirectory = edgeDownloadOutputDirectory
            selectableView.onSelectionResult = onSelectionResult
            selectableView.edgeOnlyMode = edgeOnlyMode
            selectableView.selectionDebugMode = selectionDebugMode
            selectableView.selectionDebugOutputDirectory = selectionDebugOutputDirectory
            selectableView.loaderMetadata = loaderMetadata
            if sceneChanged {
                selectableView.importedTopologyHints = topologyHints
            }
            selectableView.onSelectionDebugEvent = onSelectionDebugEvent
            selectableView.onMeasurementStateChanged = onMeasurementStateChanged
            selectableView.manualSelectionEnabled = manualSelectionEnabled
            testDriver?.bind(to: selectableView)
            selectionDriver?.bind(to: selectableView)
            if sceneChanged {
                selectableView.prepareSelectionIndexes()
            }
        }
    }
}

final class DebugSelectableSCNView: SCNView, SCNSceneRendererDelegate {
    let selectionRootName = "__selection_debug_overlay"
    let hoverRootName = "__selection_hover_overlay"
    let highlightStrokePixelRadius: CGFloat = 2.2
    let highlightEndpointPixelRadius: CGFloat = 5.0
    let edgeSelectionRadiusViewportFraction: Float = 0.0016
    let edgeSelectionRadiusWorldMin: Float = 0.0005
    let edgeSelectionRadiusWorldMax: Float = 0.45
    var screenStableHighlightNodes: [ScreenStableHighlightNode] = []
    var hoverScreenStableHighlightNodes: [ScreenStableHighlightNode] = []
    var edgeFitSettings = EdgeFitSettings()
    var edgeProbeMode = false
    var edgeSelectionMode: EdgeSelectionMode = .fitted
    var edgeProbeOutputDirectory = "/tmp/quicklook-edge-probe"
    var surfaceProbeMode = false
    var surfaceProbeOutputDirectory = "/tmp/quicklook-surface-probe"
    var edgeProbeModelHint = ""
    var edgeDownloadOutputDirectory = "/tmp/quicklook-edge-download"
    var onSelectionResult: ((EdgeSelectionDownload?) -> Void)?
    var edgeOnlyMode = false
    var selectionDebugMode = false
    var selectionDebugOutputDirectory = "/tmp/quicklook-selection-debug"
    var loaderMetadata: [String: String] = [:]
    var importedTopologyHints: ImportedTopologyHints = .empty
    var onSelectionDebugEvent: ((SelectionDebugEvent) -> Void)?
    var onMeasurementStateChanged: ((SelectionMeasurementState) -> Void)?
    var manualSelectionEnabled = true
    var activeSurfaceHighlight: (node: SCNNode, triangleIndices: [Int])?
    var activeSurfaceHighlights: [String: SurfaceHighlightRecord] = [:]
    var measurementState: SelectionMeasurementState = .empty
    var measurementAnalysisGeneration = 0
    var selectionEngineCache: [ObjectIdentifier: SceneSelectionEngine] = [:]
    var pendingSelectionEngineKeys: Set<ObjectIdentifier> = []
    var selectionIndexGeneration = 0
    var cachedMeshSettings = EdgeFitSettings()
    var mouseDownPoint: CGPoint?
    var mouseDraggedPastSelectionThreshold = false
    let cameraDragSelectionThreshold: CGFloat = 4
    let metalFeatureDistanceThreshold = SelectionMetalAccelerator.minimumSegmentThreshold
    var selectionDistanceBackend: SelectionDistanceBackend? = SelectionMetalAccelerator()
    var loggedSelectionAccelerationModes: Set<String> = []
    lazy var selectionController = SelectionController(viewport: self)
    var pendingSelectionBeforeImage: NSImage?
    var selectionTrackingArea: NSTrackingArea?
    var lastSelectionRejectionCode: QuickLookCore.SelectionRejectionCode?
    var selectionDebugScreenshotsEnabled: Bool {
        ProcessInfo.processInfo.environment["QLS_DISABLE_SELECTION_DEBUG_SCREENSHOTS"] != "1"
    }
    var pointSelectionEnabled: Bool {
        ProcessInfo.processInfo.environment["QLS_DISABLE_POINT_SELECTION"] != "1"
    }

    struct ScreenStableHighlightNode {
        let node: SCNNode
        let anchor: SIMD3<Float>
        let pixelRadius: CGFloat
        let scaleMode: HighlightScaleMode
    }

    enum HighlightScaleMode {
        case radial
        case uniform
    }

    override func updateTrackingAreas() {
        if let selectionTrackingArea {
            removeTrackingArea(selectionTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        selectionTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        selectionController.requestPreview(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        selectionController.requestPreview(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        selectionController.clearPreview()
        super.mouseExited(with: event)
    }

    struct SurfaceHighlightRecord {
        weak var node: SCNNode?
        let triangleIndices: [Int]
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDraggedPastSelectionThreshold = false
        pendingSelectionBeforeImage = selectionDebugMode && selectionDebugScreenshotsEnabled
            ? captureSelectionDebugSnapshot()
            : nil
        selectionController.suspendPreview()
        super.mouseDown(with: event)
    }

    func captureSelectionDebugSnapshot() -> NSImage {
        let image = snapshot()
        // SCNView can defer the Metal readback until NSImage is consumed. Resolve it here so
        // debug capture time does not spill into and inflate the following hit-test timing.
        _ = image.tiffRepresentation
        return image
    }

    override func mouseDragged(with event: NSEvent) {
        if let mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
            if distance > cameraDragSelectionThreshold {
                mouseDraggedPastSelectionThreshold = true
                selectionController.clearPreview(clearPointer: false, clearSnapshot: true)
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let releaseDistance = mouseDownPoint.map {
            hypot(point.x - $0.x, point.y - $0.y)
        } ?? 0

        guard manualSelectionEnabled else {
            super.mouseUp(with: event)
            mouseDownPoint = nil
            mouseDraggedPastSelectionThreshold = false
            pendingSelectionBeforeImage = nil
            selectionController.resumePreview(at: point)
            return
        }

        guard mouseDraggedPastSelectionThreshold == false,
              releaseDistance <= cameraDragSelectionThreshold else {
            super.mouseUp(with: event)
            mouseDownPoint = nil
            mouseDraggedPastSelectionThreshold = false
            pendingSelectionBeforeImage = nil
            selectionController.resumePreview(at: point)
            return
        }

        _ = selectionController.select(at: point, event: event)
        selectionController.finishClick(at: point)
        super.mouseUp(with: event)
        mouseDownPoint = nil
        mouseDraggedPastSelectionThreshold = false
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            selectionController.resumePreview(at: point)
        }
    }
}

typealias SceneKitView = SceneKitViewport
