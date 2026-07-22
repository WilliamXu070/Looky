import AppKit
import Foundation

@MainActor
final class SelectionController {
    private weak var viewport: DebugSelectableSCNView?

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
        viewport?.drawDebugSelection(
            at: point,
            event: event,
            expectation: expectation,
            forceDebugEvent: forceDebugEvent,
            modifierFlagsOverride: modifierFlags
        )
    }
}
