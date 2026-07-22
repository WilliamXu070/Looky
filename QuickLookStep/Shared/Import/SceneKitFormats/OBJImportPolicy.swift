import Foundation

struct OBJImportPolicy {
    let preferredMethods = ["scenekit", "modelio"]

    func materialPolicy(for url: URL) -> SceneMaterialPolicy {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .preserve
        }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: 256 * 1024),
            let text = String(data: data, encoding: .utf8)
        else {
            return .preserve
        }
        let hasMaterialDirective = text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("mtllib ") || trimmed.hasPrefix("usemtl ")
        }
        return hasMaterialDirective ? .preserve : .neutralWhenUnstyled
    }
}
