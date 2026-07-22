import Combine
import Foundation

final class ViewerTestDriver: ObservableObject {
    private weak var view: DebugSelectableSCNView?

    func bind(to view: DebugSelectableSCNView) {
        self.view = view
    }

    func performSelectAt(_ request: SelectionDebugSelectAtRequest) -> SelectionDebugEvent? {
        view?.performDebugSelectAt(request)
    }
}
