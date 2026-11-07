import ReclaimCore
import SwiftUI

struct ICloudView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("iCloud Drive", systemImage: "icloud", description: Text("Coming soon."))
            .navigationTitle("iCloud Drive")
    }
}
