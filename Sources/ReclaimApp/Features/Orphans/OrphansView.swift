import ReclaimCore
import SwiftUI

struct OrphansView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("App Leftovers", systemImage: "questionmark.folder", description: Text("Coming soon."))
            .navigationTitle("App Leftovers")
    }
}
