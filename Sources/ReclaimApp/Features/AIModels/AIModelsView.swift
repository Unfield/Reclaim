import ReclaimCore
import SwiftUI

struct AIModelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("AI Models", systemImage: "brain", description: Text("Coming soon."))
            .navigationTitle("AI Models")
    }
}
