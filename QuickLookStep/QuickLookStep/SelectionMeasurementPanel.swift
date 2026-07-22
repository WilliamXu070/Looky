import SwiftUI

struct SelectionMeasurementPanel: View {
    let state: SelectionMeasurementState
    @Binding var unit: MeasurementUnit
    @Binding var mmPerSourceUnit: Double
    let scaleIsAssumed: Bool
    var onResetScale: () -> Void
    var onRemoveEntity: (String) -> Void
    var onClose: () -> Void

    @State private var showDetails = false
    @State private var showScaleEditor = false

    private let panelWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider().opacity(0.45)
            selectedEntities

            if let relationshipTitle {
                Text(relationshipTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.top, 2)
            }

            measurementRows(primaryRows)

            if let detail = state.summary.distanceDetail {
                Divider().opacity(0.4)
                detailDisclosure(detail)
            }

            Divider().opacity(0.45)
            footer
        }
        .padding(12)
        .frame(width: panelWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.14), radius: 20, x: 0, y: 10)
        .foregroundStyle(Color.primary)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "ruler")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Measure")
                .font(.system(size: 15, weight: .semibold))

            Text("\(state.entities.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide measure panel")
        }
    }

    @ViewBuilder
    private var selectedEntities: some View {
        let rows = VStack(spacing: 2) {
            ForEach(Array(state.entities.enumerated()), id: \.element.id) { index, entity in
                selectedEntityRow(entity, index: index)
            }
        }

        if state.entities.count > 4 {
            ScrollView { rows }
                .frame(height: 124)
        } else {
            rows
        }
    }

    private func selectedEntityRow(
        _ entity: SelectionMeasurementEntity,
        index: Int
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: entity.kind == .surface ? "square.grid.3x3.fill" : (entity.kind == .point ? "circle.fill" : "line.diagonal"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entity.kind == .surface ? .orange : (entity.kind == .point ? .yellow : .blue))
                .frame(width: 13)

            Text(entity.label.isEmpty ? "Entity \(index + 1)" : entity.label.capitalized)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                onRemoveEntity(entity.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove selection")
        }
        .padding(.vertical, 3)
    }

    private func measurementRows(_ rows: [MeasurementRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                measurementRow(rows[index])
                if index < rows.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private func measurementRow(_ row: MeasurementRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 6)
    }

    private func detailDisclosure(_ detail: SelectionMeasurementDistanceDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showDetails.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 11)
                    Text("Details")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(formatLength(detail.minimumDistance))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 5)

            if showDetails {
                ScrollView {
                    VStack(spacing: 0) {
                        measurementRow(.init("Between", "\(detail.firstLabel) / \(detail.secondLabel)"))
                        detailVectorRows(prefix: "Min", vector: detail.minimumDeltaSIMD)
                        measurementRow(.init("Closest A", formatPoint(detail.minimumFirstPointSIMD)))
                        measurementRow(.init("Closest B", formatPoint(detail.minimumSecondPointSIMD)))

                        Divider().opacity(0.3)
                        detailVectorRows(prefix: "Max", vector: detail.maximumDeltaSIMD)
                        measurementRow(.init("Farthest A", formatPoint(detail.maximumFirstPointSIMD)))
                        measurementRow(.init("Farthest B", formatPoint(detail.maximumSecondPointSIMD)))

                        ForEach(Array(state.entities.prefix(2))) { entity in
                            if let origin = simd3(entity.origin) {
                                measurementRow(.init("\(entity.label) Center", formatPoint(origin)))
                            }
                            if let axis = simd3(entity.axis ?? entity.normal) {
                                measurementRow(.init("\(entity.label) Axis", formatVector(axis)))
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
                .padding(.leading, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func detailVectorRows(prefix: String, vector: SIMD3<Float>?) -> some View {
        if let vector {
            axisRow(axis: "X", color: .red, label: "\(prefix) X", value: vector.x)
            axisRow(axis: "Y", color: .green, label: "\(prefix) Y", value: vector.y)
            axisRow(axis: "Z", color: .blue, label: "\(prefix) Z", value: vector.z)
        }
    }

    private func axisRow(axis: String, color: Color, label: String, value: Float) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(axis)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 11)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(formatSignedLength(value))
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("Unit", selection: $unit) {
                ForEach(MeasurementUnit.visibleCases) { unit in
                    Text(unit.shortLabel).tag(unit)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 116)

            Spacer(minLength: 8)

            Button {
                showScaleEditor.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 20)
                    .overlay(alignment: .topTrailing) {
                        if scaleIsAssumed {
                            Circle()
                                .fill(.orange)
                                .frame(width: 5, height: 5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Measurement scale")
            .popover(isPresented: $showScaleEditor, arrowEdge: .bottom) {
                scaleEditor
            }
        }
    }

    private var scaleEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scale")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 7) {
                Text("1 source unit =")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("1", value: $mmPerSourceUnit, formatter: Self.scaleFormatter)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 68)
                    .textFieldStyle(.roundedBorder)
                Text("mm")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button("Reset to imported scale", action: onResetScale)
                .font(.system(size: 12))
                .disabled(scaleIsAssumed)
        }
        .padding(12)
        .frame(width: 260)
    }

    private var relationshipTitle: String? {
        guard state.entities.count == 2, let relation = state.summary.relation else { return nil }
        return relation.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var primaryRows: [MeasurementRow] {
        let summary = state.summary
        if state.entities.count == 1, let entity = state.entities.first {
            return singleRows(entity, summary: summary)
        }
        if state.entities.count == 2, let detail = summary.distanceDetail {
            return pairRows(detail, summary: summary)
        }

        var rows = [MeasurementRow("Entities", "\(state.entities.count)")]
        appendLengthRow("Total Length", summary.totalLength, to: &rows)
        appendAreaRow("Total Area", summary.area, to: &rows)
        appendLengthRow("Closest Pair", summary.minimumDistance, to: &rows)
        return rows
    }

    private func singleRows(
        _ entity: SelectionMeasurementEntity,
        summary: SelectionMeasurementSummary
    ) -> [MeasurementRow] {
        var rows: [MeasurementRow] = []
        if entity.kind == .point, let point = simd3(entity.origin) {
            rows.append(.init("X", formatSignedLength(point.x)))
            rows.append(.init("Y", formatSignedLength(point.y)))
            rows.append(.init("Z", formatSignedLength(point.z)))
            return rows
        }
        switch entity.geometryKind {
        case .point:
            break
        case .line:
            appendLengthRow("Length", summary.length ?? summary.totalLength, to: &rows)
        case .arc:
            appendLengthRow("Arc Length", summary.length ?? summary.totalLength, to: &rows)
            appendLengthRow("Radius", summary.radius, to: &rows)
            if let length = summary.length, let radius = summary.radius, radius > 0 {
                rows.append(.init("Sweep", formatAngle(length / radius * 180 / .pi)))
            }
        case .circle:
            appendLengthRow("Diameter", summary.radius.map { $0 * 2 }, to: &rows)
            appendLengthRow("Radius", summary.radius, to: &rows)
            appendLengthRow("Circumference", summary.length ?? summary.totalLength, to: &rows)
        case .plane:
            appendAreaRow("Area", summary.area, to: &rows)
            appendLengthRow("Perimeter", summary.perimeter, to: &rows)
        case .cylinder:
            appendAreaRow("Area", summary.area, to: &rows)
            appendLengthRow("Radius", summary.radius, to: &rows)
            appendLengthRow("Diameter", summary.radius.map { $0 * 2 }, to: &rows)
        case .other:
            if entity.kind == .edge {
                appendLengthRow("Length", summary.length ?? summary.totalLength, to: &rows)
            } else {
                appendAreaRow("Area", summary.area, to: &rows)
                appendLengthRow("Perimeter", summary.perimeter, to: &rows)
            }
        }
        return rows
    }

    private func pairRows(
        _ detail: SelectionMeasurementDistanceDetail,
        summary: SelectionMeasurementSummary
    ) -> [MeasurementRow] {
        var rows: [MeasurementRow] = []
        let firstKind = detail.firstGeometryKind ?? "other"
        let secondKind = detail.secondGeometryKind ?? "other"
        let bothLines = firstKind == "line" && secondKind == "line"
        let circularPair = [firstKind, secondKind].allSatisfy { $0 == "circle" || $0 == "arc" }
        let planePair = firstKind == "plane" && secondKind == "plane"
        let cylinderPair = firstKind == "cylinder" && secondKind == "cylinder"

        if bothLines && (detail.relation == "parallel" || detail.relation == "coincident") {
            appendLengthRow("Parallel Distance", summary.minimumDistance, to: &rows)
        } else if circularPair {
            appendLengthRow("Center Distance", summary.centerToCenterDistance, to: &rows)
            appendLengthRow("Minimum Gap", summary.minimumDistance, to: &rows)
            appendLengthRow("Maximum Span", summary.maximumDistance, to: &rows)
            appendLengthRow("Radius Difference", summary.radialGap, to: &rows)
            return rows
        } else if planePair && detail.relation == "parallel" {
            appendLengthRow("Separation", summary.minimumDistance, to: &rows)
        } else if cylinderPair {
            appendLengthRow("Axis Distance", summary.axisDistance, to: &rows)
            appendLengthRow("Surface Gap", summary.minimumDistance, to: &rows)
            appendLengthRow("Radius Difference", summary.radialGap, to: &rows)
        }

        if detail.relation != "parallel" && detail.relation != "coincident" {
            appendAngleRow("Angle", summary.angleDegrees, to: &rows)
        }
        appendLengthRow("Minimum Distance", summary.minimumDistance, to: &rows)
        appendLengthRow("Maximum Distance", summary.maximumDistance, to: &rows)
        appendLengthRow("Total Length", summary.totalLength, to: &rows)
        appendAreaRow("Total Area", summary.area, to: &rows)
        return rows
    }

    private func appendLengthRow(_ label: String, _ value: Float?, to rows: inout [MeasurementRow]) {
        guard value != nil else { return }
        rows.append(.init(label, formatLength(value)))
    }

    private func appendAreaRow(_ label: String, _ value: Float?, to rows: inout [MeasurementRow]) {
        guard value != nil else { return }
        rows.append(.init(label, formatArea(value)))
    }

    private func appendAngleRow(_ label: String, _ value: Float?, to rows: inout [MeasurementRow]) {
        guard value != nil else { return }
        rows.append(.init(label, formatAngle(value)))
    }

    private func formatLength(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "" }
        let converted = unit.convertLength(value, mmPerModelUnit: sanitizedScale)
        return "\(formatNumber(converted)) \(unit.shortLabel)"
    }

    private func formatSignedLength(_ value: Float) -> String {
        let converted = unit.convertLength(value, mmPerModelUnit: sanitizedScale)
        let sign = converted > 0 ? "+" : ""
        return "\(sign)\(formatNumber(converted)) \(unit.shortLabel)"
    }

    private func formatArea(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "" }
        let converted = unit.convertArea(value, mmPerModelUnit: sanitizedScale)
        return "\(formatNumber(converted)) \(unit.areaLabel)"
    }

    private func formatAngle(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "" }
        return "\(formatNumber(Double(value))) deg"
    }

    private func formatPoint(_ point: SIMD3<Float>?) -> String {
        guard let point else { return "" }
        return [point.x, point.y, point.z]
            .map { formatNumber(unit.convertLength($0, mmPerModelUnit: sanitizedScale)) }
            .joined(separator: ", ")
    }

    private func formatVector(_ vector: SIMD3<Float>) -> String {
        [vector.x, vector.y, vector.z]
            .map { formatNumber(Double($0)) }
            .joined(separator: ", ")
    }

    private func formatNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(value) >= 100 ? 2 : 3
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.3f", value)
    }

    private func simd3(_ values: [Float]?) -> SIMD3<Float>? {
        guard let values, values.count >= 3 else { return nil }
        return SIMD3<Float>(values[0], values[1], values[2])
    }

    private var sanitizedScale: Double { max(mmPerSourceUnit, 0.000001) }

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
