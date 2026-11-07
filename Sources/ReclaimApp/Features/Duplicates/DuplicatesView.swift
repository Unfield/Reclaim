import ReclaimCore
import SwiftUI

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<DuplicateGroup.ID> = []
    @State private var confirmingTrash = false

    var body: some View {
        let duplicates = model.duplicates

        content(duplicates)
            .topBar { DuplicatesControls(duplicates: duplicates) }
            .bottomBar {
                ActivityIndicator(isActive: duplicates.isScanning || duplicates.isTrashing)
                Text(summary(duplicates))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("Files count as duplicates only if every byte is identical. Hidden files, apps and libraries (like Photos) are skipped. Copies made in Finder on APFS disks can share storage (clones), so removing them may free less space than shown.")
                Spacer()
                Button("Move to Trash…") { confirmingTrash = true }
                    .primaryButtonStyle()
                    .disabled(duplicates.selection.isEmpty || duplicates.isScanning || duplicates.isTrashing)
            }
            .navigationTitle("Duplicates")
            .onDisappear { duplicates.cancel() }
            .confirmationDialog(
                "Move \(countText(duplicates.selectedCount)) to the Trash?",
                isPresented: $confirmingTrash
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await duplicates.moveSelectionToTrash(using: model) }
                }
            } message: {
                Text("One copy of each file is kept. This frees about \(ByteSize.format(duplicates.selectedSavings)) once you empty the Trash. You can put them back from Recently Removed.")
            }
            .alert(
                "Some files were kept",
                isPresented: Binding(get: { duplicates.removalProblem != nil }, set: { if !$0 { duplicates.removalProblem = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(duplicates.removalProblem ?? "")
            }
    }

    @ViewBuilder
    private func content(_ duplicates: DuplicatesModel) -> some View {
        if duplicates.isScanning {
            ContentUnavailableView {
                Label("Looking for Duplicates", systemImage: "doc.on.doc")
            } description: {
                Text(progressText(duplicates.progress)).monospacedDigit()
            } actions: {
                VStack(spacing: 14) {
                    Group {
                        if let fraction = duplicates.progress.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                    .frame(width: 260)
                    Button("Stop") { duplicates.cancel() }
                        .secondaryButtonStyle()
                }
            }
        } else if !duplicates.hasScanned {
            ContentUnavailableView {
                Label("Find Duplicate Files", systemImage: "doc.on.doc")
            } description: {
                Text("Find identical copies of files in the folders above, then keep one and move the rest to the Trash.")
            } actions: {
                Button("Scan") { duplicates.scan() }
                    .primaryButtonStyle()
                    .disabled(!duplicates.canScan)
            }
        } else if duplicates.groups.isEmpty {
            ContentUnavailableView {
                Label("No Duplicates", systemImage: "checkmark.circle")
            } description: {
                Text("No identical files of \(ByteSize.format(duplicates.minimumSize)) or more in these folders.")
            } actions: {
                Button("Scan Again") { duplicates.scan() }
                    .secondaryButtonStyle()
            }
        } else {
            List {
                if duplicates.unreadableCount > 0 {
                    FullDiskAccessBanner(count: duplicates.unreadableCount)
                        .listRowSeparator(.hidden)
                }
                ForEach(duplicates.groups) { group in
                    DisclosureGroup(isExpanded: expansion(of: group.id)) {
                        ForEach(group.files) { file in
                            DuplicateFileRow(duplicates: duplicates, group: group, file: file)
                        }
                    } label: {
                        DuplicateGroupRow(duplicates: duplicates, group: group) {
                            expansion(of: group.id).wrappedValue.toggle()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func expansion(of id: DuplicateGroup.ID) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }

    private func summary(_ duplicates: DuplicatesModel) -> String {
        guard duplicates.hasScanned, !duplicates.groups.isEmpty else {
            return duplicates.isScanning ? String(localized: "Searching…") : String(localized: "Compares files byte for byte")
        }
        let wasted = String(localized: "\(ByteSize.format(duplicates.wastedSpace)) in duplicates")
        guard duplicates.selectedCount > 0 else { return wasted + " · " + String(localized: "nothing selected") }
        return wasted + " · "
            + String(localized: "\(countText(duplicates.selectedCount)) selected (\(ByteSize.format(duplicates.selectedSavings)))")
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 duplicate") : String(localized: "\(count) duplicates")
    }

    private func progressText(_ progress: DuplicateScanProgress) -> String {
        switch progress.phase {
        case .searching:
            String(localized: "Looking at files… \(progress.filesExamined.formatted())")
        case .comparing:
            String(localized: "Comparing \(progress.filesTotal.formatted()) files with matching sizes…")
        case .verifying:
            String(localized: "Checking contents: \(ByteSize.format(progress.bytesHashed)) of \(ByteSize.format(progress.bytesToHash))")
        }
    }
}

// MARK: - Controls

private struct DuplicatesControls: View {
    @Environment(AppModel.self) private var model
    @Bindable var duplicates: DuplicatesModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Search in").foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if duplicates.roots.isEmpty {
                        Text("No folders yet").foregroundStyle(.tertiary)
                    }
                    ForEach(duplicates.roots, id: \.self) { root in
                        RootChip(
                            title: title(for: root),
                            systemImage: VolumeInfo.volume(containing: root, in: model.volumes)?.symbolName ?? "folder",
                            path: root.abbreviatedPath,
                            isAvailable: duplicates.isAvailable(root)
                        ) {
                            duplicates.removeRoot(root)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            addMenu
        }

        HStack(spacing: 10) {
            Picker("Larger than", selection: $duplicates.minimumSize) {
                ForEach(DuplicatesModel.sizeOptions, id: \.self) { Text(ByteSize.format($0)).tag($0) }
            }
            .fixedSize()
            Picker("Keep", selection: $duplicates.keepRule) {
                ForEach(DuplicateKeepRule.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help("Which copy of each file to keep. The other copies are checked for removal; you can change any of them.")
            Spacer()
            Button {
                if duplicates.isScanning { duplicates.cancel() } else { duplicates.scan() }
            } label: {
                Text(duplicates.isScanning ? "Stop" : "Scan").frame(minWidth: 44)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!duplicates.isScanning && !duplicates.canScan)
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                duplicates.addRoot(FileManager.default.homeDirectoryForCurrentUser)
            } label: {
                Label("Home Folder", systemImage: "house")
            }
            Section("Disks") {
                ForEach(model.volumes) { volume in
                    Button {
                        duplicates.addRoot(volume.url)
                    } label: {
                        Label(volume.name, systemImage: volume.symbolName)
                    }
                }
            }
            Divider()
            Button("Choose Folder…") {
                let start = duplicates.roots.last ?? FileManager.default.homeDirectoryForCurrentUser
                if let url = AppModel.chooseFolder(startingAt: start) { duplicates.addRoot(url) }
            }
        } label: {
            Label("Add Folder", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Add a folder or disk to search")
    }

    private func title(for root: URL) -> String {
        if let volume = model.volumes.first(where: { $0.url.normalizedPath == root.normalizedPath }) { return volume.name }
        if root.normalizedPath == FileManager.default.homeDirectoryForCurrentUser.normalizedPath { return String(localized: "Home") }
        return root.lastPathComponent
    }
}

private struct RootChip: View {
    let title: String
    let systemImage: String
    let path: String
    let isAvailable: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Don't search \(title)")
        }
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .opacity(isAvailable ? 1 : 0.5)
        .help(isAvailable ? path : String(localized: "\(path) isn't available and will be skipped"))
    }
}

// MARK: - Rows

private struct DuplicateGroupRow: View {
    let duplicates: DuplicatesModel
    let group: DuplicateGroup
    let onToggleExpansion: () -> Void

    var body: some View {
        let kept = duplicates.keptFile(in: group) ?? group.files[0]

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { duplicates.isGroupSelected(group) },
                set: { duplicates.setGroup(group, selected: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Remove the extra copies of this file")

            HStack(spacing: 10) {
                FileIcon(url: kept.url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kept.name).lineLimit(1)
                    Text(subtitle(kept: kept))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if group.hasClones {
                    Image(systemName: "square.on.square.dashed")
                        .foregroundStyle(.secondary)
                        .help("Some copies are APFS clones that share storage, so removing them frees less space.")
                }
                SizeText(bytes: group.wastedSpace)
                    .frame(width: 90, alignment: .trailing)
                    .help("Space used by the extra copies")
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpansion)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal Kept Copy in Finder") { AppModel.revealInFinder(kept.url) }
        }
    }

    private func subtitle(kept: DuplicateFile) -> String {
        let selected = duplicates.selection.selectedFiles(in: group).count
        let keeping = selected > 0 ? String(localized: "keeping the one in \(kept.folder.abbreviatedPath)") : String(localized: "keeping all")
        return String(localized: "\(group.files.count) copies of \(ByteSize.format(group.size))") + " · " + keeping
    }
}

private struct DuplicateFileRow: View {
    let duplicates: DuplicatesModel
    let group: DuplicateGroup
    let file: DuplicateFile

    var body: some View {
        let isSelected = duplicates.isSelected(file)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { duplicates.isSelected(file) },
                set: { duplicates.setSelected(file, $0, in: group) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(isSelected ? "Will be moved to the Trash" : "Will be kept")

            FileIcon(url: file.url, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1)
                Text(file.folder.abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)

            Image(systemName: "square.on.square.dashed")
                .foregroundStyle(.secondary)
                .opacity(group.sharesStorage(file) ? 1 : 0)
                .help("This copy is an APFS clone and shares storage with another copy.")
                .accessibilityHidden(!group.sharesStorage(file))

            Text(isSelected ? "Remove" : "Keep")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.secondary : Color.green)
                .frame(width: 56, alignment: .center)

            Text(file.modified.shortDate)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 100, alignment: .trailing)

            Button {
                AppModel.revealInFinder(file.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button("Reveal in Finder") { AppModel.revealInFinder(file.url) }
            Button("Keep Only This Copy") { duplicates.keepOnly(file, in: group) }
        }
    }
}
