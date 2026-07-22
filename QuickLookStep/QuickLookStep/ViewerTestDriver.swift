import Combine
import Foundation

@MainActor
final class ViewerTestDriver: ObservableObject {
    private weak var view: DebugSelectableSCNView?
    private(set) var lastPerformedHoverSummary: HoverSelectionSummary?

    func bind(to view: DebugSelectableSCNView) {
        self.view = view
    }

    func performSelectAt(_ request: SelectionDebugSelectAtRequest) -> SelectionDebugEvent? {
        view?.performDebugSelectAt(request)
    }

    func performHoverAt(_ request: SelectionDebugHoverAtRequest) -> HoverSelectionSnapshot? {
        let snapshot = view?.performDebugHoverAt(request)
        lastPerformedHoverSummary = snapshot?.summary
        return snapshot
    }

    func clearHover() {
        view?.performDebugClearHover()
        lastPerformedHoverSummary = nil
    }

    var hoverSummary: HoverSelectionSummary? {
        view?.selectionController.hoverSnapshot?.summary
    }

    var hoverResolverPassCount: Int {
        view?.selectionController.resolutionPassCount ?? 0
    }
}
