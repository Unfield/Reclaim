import ReclaimCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("CPU & Energy", systemImage: "cpu", description: Text("Coming soon."))
            .navigationTitle("CPU & Energy")
    }
}
