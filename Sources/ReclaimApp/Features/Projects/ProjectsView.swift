import ReclaimCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Developer Projects", systemImage: "hammer", description: Text("Coming soon."))
            .navigationTitle("Developer Projects")
    }
}
