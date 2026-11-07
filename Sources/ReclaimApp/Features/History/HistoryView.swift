import ReclaimCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Disk History", systemImage: "chart.xyaxis.line", description: Text("Coming soon."))
            .navigationTitle("Disk History")
    }
}
