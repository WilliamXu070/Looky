import Foundation

struct STLImportPolicy {
    let preferredMethods = ["scenekit", "modelio"]
    let materialPolicy: SceneMaterialPolicy = .neutralWhenUnstyled
}
