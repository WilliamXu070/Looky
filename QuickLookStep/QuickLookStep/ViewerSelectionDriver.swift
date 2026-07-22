import Combine
import Foundation

@MainActor
final class ViewerSelectionDriver: ObservableObject {
    private weak var view: DebugSelectableSCNView?

    func bind(to view: DebugSelectableSCNView) {
        self.view = view
    }

    func removeMeasurementEntity(id: String) {
        view?.removeMeasurementEntity(id: id)
    }
}
