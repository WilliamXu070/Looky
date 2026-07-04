import SwiftUI

struct SelectionMeasurementPanel: View {
    let state: SelectionMeasurementState
    @Binding var unit: MeasurementUnit
    @Binding var mmPerModelUnit: Double
    var onClose: () -> Void

    @State private var showDistanceDetails = false

    private let panelWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()
                .opacity(0.55)

            if !state.entities.isEmpty {
                selectedEntities
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        measurementRow(rows[index])
                        if index < rows.count - 1 {
                            Divider()
                                .opacity(0.45)
                        }
                    }

                    if let detail = state.summary.distanceDetail {
                        Divider()
                            .opacity(0.45)
                        distanceDetails(detail)
                    }
                }
            }
            .frame(maxHeight: 320)

            Divider()
                .opacity(0.55)

            footer
        }
        .padding(14)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.36), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 22, x: 0, y: 12)
        .foregroundStyle(Color.primary)
    }

    private var selectedEntities: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(Array(state.entities.enumerated()), id: \.element.id) { index, entity in
                    HStack(spacing: 8) {
                        Image(systemName: entity.kind == "surface" ? "square.grid.3x3.fill" : "line.diagonal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(entity.kind == "surface" ? .orange : .blue)
                            .frame(width: 14)

                        Text(entity.label.isEmpty ? "Entity \(index + 1)" : entity.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if let length = entity.length {
                            Text(formatLength(length))
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ruler")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            Text("Measurement")
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(selectionBadge)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(badgeColor.opacity(0.10))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(badgeColor.opacity(0.28), lineWidth: 1)
                }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide measurement panel")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("Unit", selection: $unit) {
                ForEach(MeasurementUnit.allCases) { unit in
                    Text(unit.shortLabel).tag(unit)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 128)

            Spacer(minLength: 6)

            Text("1u =")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("1.0", value: $mmPerModelUnit, formatter: Self.scaleFormatter)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)

            Text("mm")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func measurementRow(_ row: MeasurementRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 10)

            Text(row.value)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 8)
    }

    private func distanceDetails(_ detail: SelectionMeasurementDistanceDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showDistanceDetails.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showDistanceDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 12)
                    Text("Distance Details")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(formatLength(detail.minimumDistance))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)

            if showDistanceDetails {
                VStack(spacing: 0) {
                    measurementRow(.init("Between", "\(detail.firstLabel) - \(detail.secondLabel)"))
                    measurementRow(.init("Min Distance", formatLength(detail.minimumDistance)))
                    axisRows(prefix: "Min", delta: detail.minimumDeltaSIMD)
                    pointRows(prefix: "A", point: detail.minimumFirstPointSIMD)
                    pointRows(prefix: "B", point: detail.minimumSecondPointSIMD)

                    Divider()
                        .opacity(0.35)
                        .padding(.vertical, 2)

                    measurementRow(.init("Max Distance", formatLength(detail.maximumDistance)))
                    axisRows(prefix: "Max", delta: detail.maximumDeltaSIMD)
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func axisRows(prefix: String, delta: SIMD3<Float>?) -> some View {
        if let delta {
            measurementRow(.init("\(prefix) X", formatSignedLength(delta.x)))
            measurementRow(.init("\(prefix) Y", formatSignedLength(delta.y)))
            measurementRow(.init("\(prefix) Z", formatSignedLength(delta.z)))
        }
    }

    @ViewBuilder
    private func pointRows(prefix: String, point: SIMD3<Float>?) -> some View {
        if let point {
            measurementRow(.init("\(prefix) XYZ", formatPoint(point)))
        }
    }

    private var rows: [MeasurementRow] {
        let summary = state.summary
        switch summary.kind {
        case "surface":
            return [
                .init("Area", formatArea(summary.area)),
                .init("Perimeter", formatLength(summary.perimeter)),
                .init("Triangles", formatCount(summary.triangleCount)),
                .init("Type", summary.surfaceType ?? "-"),
            ]
        case "multiEdge":
            return [
                .init("Total Length", formatLength(summary.totalLength)),
                .init("Minimum Distance", formatLength(summary.minimumDistance)),
                .init("Maximum Distance", formatLength(summary.maximumDistance)),
                .init("Center-to-Center", formatLength(summary.centerToCenterDistance)),
                .init("Angle", formatAngle(summary.angleDegrees)),
                .init("Points", formatCount(summary.pointCount)),
            ]
        case "edge":
            return [
                .init("Length", formatLength(summary.length ?? summary.totalLength)),
                .init("Radius", formatLength(summary.radius)),
                .init("Shape", summary.shape ?? "-"),
                .init("Points", formatCount(summary.pointCount)),
            ]
        default:
            return [.init("Selection", "None")]
        }
    }

    private var selectionBadge: String {
        switch state.summary.kind {
        case "surface":
            return "Surface"
        case "multiEdge":
            return "\(state.summary.entityCount) Edges"
        case "edge":
            return "Single"
        default:
            return "Empty"
        }
    }

    private var badgeColor: Color {
        switch state.summary.kind {
        case "surface":
            return .orange
        case "multiEdge":
            return .blue
        case "edge":
            return .orange
        default:
            return .secondary
        }
    }

    private func formatLength(_ value: Float?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }
        let converted = unit.convertLength(value, mmPerModelUnit: sanitizedScale)
        return "\(formatNumber(converted)) \(unit.shortLabel)"
    }

    private func formatSignedLength(_ value: Float?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }
        let converted = unit.convertLength(value, mmPerModelUnit: sanitizedScale)
        let sign = converted > 0 ? "+" : ""
        return "\(sign)\(formatNumber(converted)) \(unit.shortLabel)"
    }

    private func formatArea(_ value: Float?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }
        let converted = unit.convertArea(value, mmPerModelUnit: sanitizedScale)
        return "\(formatNumber(converted)) \(unit.areaLabel)"
    }

    private func formatAngle(_ value: Float?) -> String {
        guard let value, value.isFinite else {
            return "-"
        }
        return "\(formatNumber(Double(value))) deg"
    }

    private func formatCount(_ value: Int?) -> String {
        guard let value else {
            return "-"
        }
        return "\(value)"
    }

    private func formatPoint(_ point: SIMD3<Float>) -> String {
        let x = unit.convertLength(point.x, mmPerModelUnit: sanitizedScale)
        let y = unit.convertLength(point.y, mmPerModelUnit: sanitizedScale)
        let z = unit.convertLength(point.z, mmPerModelUnit: sanitizedScale)
        return "\(formatNumber(x)), \(formatNumber(y)), \(formatNumber(z))"
    }

    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value >= 100 ? 2 : 3
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.3f", value)
    }

    private var sanitizedScale: Double {
        max(mmPerModelUnit, 0.000001)
    }

    private struct MeasurementRow {
        let label: String
        let value: String

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    private static let scaleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.minimum = 0.000001
        return formatter
    }()
}
