import SwiftUI

struct SelectionMeasurementPanel: View {
    let state: SelectionMeasurementState
    @Binding var unit: MeasurementUnit
    @Binding var mmPerModelUnit: Double
    var onClose: () -> Void

    private let panelWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()
                .opacity(0.55)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        measurementRow(rows[index])
                        if index < rows.count - 1 {
                            Divider()
                                .opacity(0.45)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)

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
