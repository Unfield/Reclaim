import ReclaimCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Duplicates", systemImage: "doc.on.doc", description: Text("Coming soon."))
            .navigationTitle("Duplicates")
    }
}
