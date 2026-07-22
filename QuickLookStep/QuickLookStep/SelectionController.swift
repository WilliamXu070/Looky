import AppKit
import Foundation

@MainActor
final class SelectionController {
    private weak var viewport: DebugSelectableSCNView?
    private(set) var latestPointerPoint: CGPoint?
    private(set) var hoverSnapshot: HoverSelectionSnapshot?
    private var previewScheduled = false
    private var previewSuspended = false
    private var lastEvaluatedCamera: SelectionCameraSignature?
    private(set) var resolutionPassCount = 0

    init(viewport: DebugSelectableSCNView) {
        self.viewport = viewport
    }

    @discardableResult
    func select(
        at point: CGPoint,
        event: NSEvent?,
        expectation: SelectionDebugExpectation? = nil,
        forceDebugEvent: Bool = false,
        modifierFlags: [String]? = nil
    ) -> SelectionDebugEvent? {
        guard let viewport else { return nil }
        let camera = viewport.selectionCameraSignature()
        let commitSource: SelectionCommitSource
        if let hoverSnapshot,
           hoverSnapshot.selectionGeneration == viewport.selectionIndexGeneration,
           hoverSnapshot.camera == camera,
           hypot(point.x - hoverSnapshot.point.x, point.y - hoverSnapshot.point.y) <= 2 {
            commitSource = .cached(hoverSnapshot.resolution)
        } else {
            commitSource = .resolve
        }
        clearPreview(clearPointer: false, clearSnapshot: true)
        lastEvaluatedCamera = camera
        return viewport.drawDebugSelection(
            at: point,
            event: event,
            expectation: expectation,
            forceDebugEvent: forceDebugEvent,
            modifierFlagsOverride: modifierFlags,
            commitSource: commitSource
        )
    }

    func requestPreview(at point: CGPoint) {
        latestPointerPoint = point
        guard !previewSuspended, !previewScheduled else { return }
        previewScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0)) { [weak self] in
            self?.flushPreview()
        }
    }

    @discardableResult
    func previewImmediately(at point: CGPoint) -> HoverSelectionSnapshot? {
        latestPointerPoint = point
        previewScheduled = false
        guard !previewSuspended, let viewport else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        resolutionPassCount += 1
        let camera = viewport.selectionCameraSignature()
        let resolution = viewport.resolveSelection(
            at: point,
            preferredEntityID: hoverSnapshot?.resolution?.entityID
        )
        let snapshot = HoverSelectionSnapshot(
            point: point,
            camera: camera,
            selectionGeneration: viewport.selectionIndexGeneration,
            resolution: resolution,
            elapsedMs: (CFAbsoluteTimeGetCurrent() - start) * 1000
        )
        hoverSnapshot = snapshot
        lastEvaluatedCamera = camera
        viewport.drawHoverSelection(resolution)
        return snapshot
    }

    func clearPreview(clearPointer: Bool = true, clearSnapshot: Bool = true) {
        if clearPointer {
            latestPointerPoint = nil
        }
        if clearSnapshot {
            hoverSnapshot = nil
        }
        viewport?.clearHoverSelection()
    }

    func suspendPreview() {
        previewSuspended = true
        clearPreview(clearPointer: false, clearSnapshot: false)
    }

    func resumePreview(at point: CGPoint? = nil) {
        previewSuspended = false
        if let point {
            latestPointerPoint = point
        }
        if let latestPointerPoint {
            requestPreview(at: latestPointerPoint)
        }
    }

    func finishClick(at point: CGPoint) {
        previewSuspended = false
        latestPointerPoint = point
    }

    func invalidatePreviewForCameraChange() {
        guard !previewSuspended,
              let latestPointerPoint,
              let viewport else {
            return
        }
        let camera = viewport.selectionCameraSignature()
        guard camera != lastEvaluatedCamera else { return }
        requestPreview(at: latestPointerPoint)
    }

    func selectionIndexDidChange() {
        hoverSnapshot = nil
        if let latestPointerPoint, !previewSuspended {
            requestPreview(at: latestPointerPoint)
        }
    }

    private func flushPreview() {
        guard previewScheduled else { return }
        previewScheduled = false
        guard let latestPointerPoint, !previewSuspended else { return }
        _ = previewImmediately(at: latestPointerPoint)
    }
}
