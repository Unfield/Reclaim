import ReclaimCore
import SwiftUI

struct LoginItemsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView("Login Items", systemImage: "power", description: Text("Coming soon."))
            .navigationTitle("Login Items")
    }
}
