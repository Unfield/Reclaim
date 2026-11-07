import ReclaimCore
import SwiftUI

/// A treemap of a folder's contents for the Space Explorer. (Placeholder: replace with the real implementation.)
struct TreemapView: View {
    let entries: [FolderEntry]
    @Binding var selection: FolderEntry.ID?
    /// Called when a folder should be opened (e.g. double-click).
    let onOpen: (FolderEntry) -> Void

    var body: some View {
        ContentUnavailableView("Treemap", systemImage: "square.grid.3x3.square", description: Text("Coming soon."))
    }
}
