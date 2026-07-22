import Foundation
import SwiftUI

extension QuickLookStepHostView {
    @ViewBuilder
    var selectionDebugHUD: some View {
        if let event = viewerSession.latestDebugEvent {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selection Debug")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("\(event.resolver.finalKind): \(event.resolver.reason)")
                    .lineLimit(2)
                Text("tris \(event.resolver.selectedSurfaceTriangleCount)  edges \(event.resolver.edgeCandidateCount)")
                Text(
                    "seed \(event.resolver.seedTriangle.map(String.init) ?? "-")  near \(formatDebugFloat(event.resolver.nearestFeatureEdgeDistance)) / \(formatDebugFloat(event.resolver.surfacePromotionThreshold))"
                )
                Text("accel \(event.resolver.nearestFeatureEdgeAcceleration ?? "-")")
                Text(
                    "vp \(formatDebugDouble(event.input.normalizedViewportPoint.first)) \(formatDebugDouble(event.input.normalizedViewportPoint.dropFirst().first))  \(event.eventID)"
                )
                if let warning = event.render.clippingWarning {
                    Text(warning)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white)
            .padding(10)
            .background(Color.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 520, alignment: .leading)
        } else {
            Text("Selection Debug: no clicks yet")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @discardableResult
    @MainActor
    func loadFile(_ url: URL) async -> (Double, String, [String: String]) {
        viewerSession.loadError = nil
        let needsSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurity { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let start = CFAbsoluteTimeGetCurrent()
            viewerSession.beginLoading(url)
            let imported = try await ModelImportPipeline.load(
                ModelLoadRequest(url: url, profile: .interactive)
            )
            try Task.checkCancellation()
            let metadata = viewerSession.completeLoading(imported)
            return ((CFAbsoluteTimeGetCurrent() - start) * 1000, imported.diagnostics.method, metadata)
        } catch is CancellationError {
            return (0, "cancelled", [:])
        } catch {
            viewerSession.failLoading(error)
            return (0, "failed:\(error.localizedDescription)", [:])
        }
    }

    private func formatDebugFloat(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.4f", value)
    }

    private func formatDebugDouble(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.3f", value)
    }
}
