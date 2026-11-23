import SwiftUI

// =============================================================================
// CollectionsView (frame G3) — collections as shooting palettes, not folders.
// 2×2 grade-mosaic covers rendered through the real pipeline, real usage
// stats, create/rename/delete, drag-to-add from a library strip, reordering,
// and "pin to camera filmstrip" which makes one collection the strip's lead
// (honoured by LookLibraryStore.stripLooks).
// =============================================================================

// MARK: - Pinned palette (read by stripLooks)

extension LookLibraryStore {
    /// Members of the collection pinned to the camera filmstrip, in stored
    /// order. Empty when nothing is pinned, which restores default ordering.
    var pinnedCollectionLooks: [LibraryLook] {
        guard let group = collectionGroups.first(where: { $0.collection.pinnedToCamera == true })
        else { return [] }
        return group.looks
    }
}

// MARK: - Screen

struct CollectionsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var thumbs = LookThumbs()

    /// The card the footer's pin action and the member strip belong to.
    @State private var selectedID: UUID?
    @State private var editMode: EditMode = .inactive
    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deleteID: UUID?
    @State private var dropTargetID: UUID?

    private var groups: [(collection: LUTCollection, looks: [LibraryLook])] {
        app.library.collectionGroups
    }

    private var selected: LUTCollection? {
        app.lutRepository.collections.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if groups.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .background(LumaTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { selectDefaultIfNeeded() }
        .task(id: "\(app.previewFrame?.extent.debugDescription ?? "none")-\(app.library.all.count)") {
            thumbs.render(source: app.previewFrame, library: app.library.all,
                          fileURL: { app.lutRepository.fileURL(for: $0) })
        }
        .alert("New collection", isPresented: $showNewAlert) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let made = app.lutRepository.createCollection(name: name)
                selectedID = made.id
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Group looks you shoot with, then pin one to the camera.")
        }
        .alert("Rename collection", isPresented: Binding(
            get: { renameID != nil },
            set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renameID { app.lutRepository.renameCollection(id, to: renameText) }
                renameID = nil
            }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
        .alert("Delete collection?", isPresented: Binding(
            get: { deleteID != nil },
            set: { if !$0 { deleteID = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleteID {
                    app.lutRepository.deleteCollection(id)
                    if selectedID == id { selectedID = nil }
                }
                deleteID = nil
            }
            Button("Cancel", role: .cancel) { deleteID = nil }
        } message: {
            Text("The looks stay in your library. Only the grouping goes.")
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    /// The calm page head: back, then the quiet Reorder and New pills on one
    /// row, the headline as a light word and a bold word, and one grey line
    /// with the count.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            LumaHeadline(light: "Your", heavy: "collections", size: 30)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(readout)
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
                .lineLimit(1)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            BackArrow()
            Spacer()
            if !groups.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        editMode = editMode == .active ? .inactive : .active
                    }
                    LumaHaptics.shared.tap()
                } label: {
                    // Labelled so the only ≡ on screen is the live drag handle
                    // the List itself supplies while reordering.
                    quietPill(editMode == .active ? "Done" : "Reorder",
                              icon: editMode == .active ? "checkmark" : "arrow.up.arrow.down",
                              on: editMode == .active)
                }
                .accessibilityLabel(editMode == .active ? "Done reordering" : "Reorder collections")
                .buttonStyle(.lumaPress)
            }
            Button {
                showNewAlert = true
                LumaHaptics.shared.tap()
            } label: {
                quietPill("New", icon: "plus", on: false)
            }
            .accessibilityLabel("New collection")
            .buttonStyle(.lumaPress)
        }
    }

    /// Quiet glass pill; white with ink text while it is on (reordering).
    private func quietPill(_ title: String, icon: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.luma(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(on ? LumaTheme.onLight : Color.white.opacity(0.92))
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
    }

    /// "3 collections · Street pinned to the camera".
    private var readout: String {
        let n = groups.count
        let base = "\(n) collection\(n == 1 ? "" : "s")"
        guard let pinned = app.lutRepository.pinnedCollection else {
            return n == 0 ? "Group the looks you shoot with" : "\(base) · none pinned to the camera"
        }
        return "\(base) · \(pinned.name) pinned to the camera"
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                ForEach(groups, id: \.collection.id) { group in
                    card(for: group)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                }
                .onMove { source, destination in
                    app.lutRepository.moveCollections(fromOffsets: source, toOffset: destination)
                    LumaHaptics.shared.reorderDrop()
                }
            }
            // Reordering and drag-to-add both claim the drag gesture, so the
            // source strip stands down while the list is in reorder mode.
            if editMode == .inactive {
                Section {
                    addLooksStrip
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 8, trailing: 0))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }

    // MARK: Collection card

    @ViewBuilder
    private func card(for group: (collection: LUTCollection, looks: [LibraryLook])) -> some View {
        let collection = group.collection
        let isSelected = selectedID == collection.id
        let isTargeted = dropTargetID == collection.id

        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    selectedID = isSelected ? nil : collection.id
                }
                LumaHaptics.shared.tap()
            } label: {
                HStack(spacing: 12) {
                    mosaic(group.looks)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(collection.name)
                                .font(.luma(size: 15, weight: .semibold))
                                .foregroundStyle(LumaTheme.textPrimary)
                                .lineLimit(1)
                            if collection.pinnedToCamera == true {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.7))
                                    .accessibilityLabel("Pinned to the camera")
                            }
                        }
                        Text(stats(for: group))
                            .font(.luma(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Disclosure state only: the reorder handle is supplied by
                    // the List in edit mode, so no decorative ≡ here.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.85 : 0.3))
                        .rotationEffect(.degrees(isSelected ? 0 : -90))
                        .opacity(editMode == .active ? 0 : 1)
                }
            }
            .buttonStyle(.lumaPress)

            if isSelected, editMode == .inactive {
                memberStrip(for: group)
            }
        }
        .padding(12)
        .background(Color.white.opacity(isTargeted ? 0.09 : 0.045),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Calm: no outline at rest. The picked card wears the pale picked
        // ring; a card a look is being dragged over brightens and lifts.
        .pickedRing(isSelected && !isTargeted, cornerRadius: 18)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
            }
        }
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isTargeted)
        .dropDestination(for: String.self) { ids, _ in
            var added = false
            for id in ids where !app.lutRepository.contains(lookID: id, in: collection.id) {
                app.lutRepository.addLook(id: id, to: collection.id)
                added = true
            }
            if added {
                selectedID = collection.id
                LumaHaptics.shared.reorderDrop()
            }
            return added
        } isTargeted: { targeted in
            dropTargetID = targeted ? collection.id : (dropTargetID == collection.id ? nil : dropTargetID)
        }
        .contextMenu {
            Button {
                renameText = collection.name
                renameID = collection.id
            } label: { Label("Rename…", systemImage: "pencil") }
            Button {
                togglePin(collection)
            } label: {
                Label(collection.pinnedToCamera == true ? "Unpin from Camera" : "Pin to Camera",
                      systemImage: collection.pinnedToCamera == true ? "pin.slash" : "pin")
            }
            Button(role: .destructive) {
                deleteID = collection.id
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// 2×2 grade mosaic from the first four members, rendered through the real
    /// pipeline. Short collections get dashed cells so the shape stays legible.
    private func mosaic(_ looks: [LibraryLook], side: CGFloat = 56) -> some View {
        let cell = (side - 3) / 2
        return VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { column in
                        mosaicCell(looks, index: row * 2 + column, side: cell)
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private func mosaicCell(_ looks: [LibraryLook], index: Int, side: CGFloat) -> some View {
        if index < looks.count, let image = thumbs.images[looks[index].thumbKey] {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Mosaic cells sit inside the collection card's Button; the
                // overflowing fill would otherwise hit-test outside the cover.
                .contentShape(RoundedRectangle(cornerRadius: 6))
        } else if index < looks.count {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.085))
                .frame(width: side, height: side)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.045))
                .frame(width: side, height: side)
        }
    }

    /// "8 looks · used in 4 projects" — usage counts real stored projects whose
    /// clips or adjustment layers carry a member look.
    private func stats(for group: (collection: LUTCollection, looks: [LibraryLook])) -> String {
        let n = group.looks.count
        let count = "\(n) look\(n == 1 ? "" : "s")"
        if group.collection.pinnedToCamera == true { return "\(count) · pinned to camera" }
        guard n > 0 else { return "Empty · drag looks in from below" }
        let projects = projectsUsing(group.looks)
        return projects == 0
            ? "\(count) · not used in a project yet"
            : "\(count) · used in \(projects) project\(projects == 1 ? "" : "s")"
    }

    private func projectsUsing(_ looks: [LibraryLook]) -> Int {
        var lutIDs = Set<UUID>()
        var names = Set<String>()
        for look in looks {
            switch look.source {
            case .lut(let f):     lutIDs.insert(f.id)
            case .builtIn(let p): names.insert(p.name)
            case .saved(let s):
                names.insert(s.baseLookName)
                if let id = s.lutID { lutIDs.insert(id) }
            }
        }
        func matches(_ grade: ClipGrade) -> Bool {
            if let id = grade.lutID, lutIDs.contains(id) { return true }
            return !grade.baseLookName.isEmpty && names.contains(grade.baseLookName)
        }
        return app.store.projects.filter { project in
            project.clips.contains { $0.grade.map(matches) ?? false }
                || (project.adjustmentLayers ?? []).contains { matches($0.grade) }
        }.count
    }

    /// Members of the selected collection, each removable — the counterpart to
    /// dragging one in.
    private func memberStrip(for group: (collection: LUTCollection, looks: [LibraryLook])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.055))
                .frame(height: 1)
            if group.looks.isEmpty {
                Text("Drag a look from the row below, or long-press one and choose Add to Collection.")
                    .font(.luma(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(group.looks) { look in
                            memberTile(look, in: group.collection)
                        }
                    }
                }
            }
        }
    }

    private func memberTile(_ look: LibraryLook, in collection: LUTCollection) -> some View {
        VStack(spacing: 4) {
            thumb(look, side: 48, radius: 10)
            // The look's name in its own colour (You › Appearance › Names).
            LookNameText(look.nameSplit.title, colour: look.signature, size: 10, weight: .medium)
                .minimumScaleFactor(0.8)
                .frame(width: 52)
        }
        .contextMenu {
            Button(role: .destructive) {
                app.lutRepository.removeLook(id: look.id, from: collection.id)
            } label: { Label("Remove from \(collection.name)", systemImage: "minus.circle") }
        }
    }

    // MARK: Add-looks strip (drag source)

    private var addLooksStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add looks")
                    .font(.luma(size: 17, weight: .semibold))
                    .kerning(-0.25)
                    .foregroundStyle(LumaTheme.textPrimary)
                Spacer(minLength: 8)
                Text(selected == nil ? "Pick a collection first" : "Drag one into a collection")
                    .font(.luma(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(app.library.all) { look in
                        sourceTile(look)
                    }
                }
                .padding(.horizontal, 20)
            }
            .lumaEdgeFade()
        }
    }

    private func sourceTile(_ look: LibraryLook) -> some View {
        VStack(spacing: 5) {
            thumb(look, side: 64, radius: 12)
            LookNameText(look.nameSplit.title, colour: look.signature, size: 11, weight: .medium)
                .minimumScaleFactor(0.8)
                .frame(width: 68)
        }
        // Lifted, tilted drag preview — direct manipulation, as in the mockup.
        .draggable(look.id) {
            thumb(look, side: 78, radius: 14)
                .rotationEffect(.degrees(-5))
                .shadow(color: .black.opacity(0.55), radius: 12, y: 8)
        }
        // Non-drag fallback so the feature never needs a precise gesture.
        .contextMenu {
            if app.lutRepository.collections.isEmpty {
                Button {
                    showNewAlert = true
                } label: { Label("New Collection…", systemImage: "folder.badge.plus") }
            } else {
                ForEach(app.lutRepository.collections) { collection in
                    let isIn = app.lutRepository.contains(lookID: look.id, in: collection.id)
                    Button {
                        app.lutRepository.toggleLook(id: look.id, in: collection.id)
                        selectedID = collection.id
                    } label: {
                        Label(isIn ? "Remove from \(collection.name)" : "Add to \(collection.name)",
                              systemImage: isIn ? "checkmark.circle.fill" : "folder.badge.plus")
                    }
                }
            }
        }
    }

    private func thumb(_ look: LibraryLook, side: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let image = thumbs.images[look.thumbKey] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.085))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        // Look thumbs sit shoulder-to-shoulder in the "add looks" rail — the
        // overflowing fill must not reach into the next tile's tap target.
        .contentShape(RoundedRectangle(cornerRadius: radius))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 64, height: 64)
                .background(Color.white.opacity(0.06), in: Circle())
            Text("No collections yet")
                .font(.luma(size: 17, weight: .semibold))
                .foregroundStyle(LumaTheme.textPrimary)
            Text("Group the looks you shoot with, then pin one collection to the camera filmstrip.")
                .font(.luma(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            // The one main action here, so it follows Main buttons.
            LumaMainButton(title: "New collection", icon: "plus", height: 50) {
                showNewAlert = true
            }
            .padding(.horizontal, 44)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    /// The screen's headline action, per §2 Unit 8 / mockup G3: a permanent
    /// bottom element, never hidden behind a selection the user has not made
    /// yet. Pinning is the one main action (it follows Main buttons); with
    /// nothing picked, or the picked one already pinned, it is quiet glass.
    @ViewBuilder
    private var footer: some View {
        if !groups.isEmpty {
            let collection = selected
            let isPinned = collection?.pinnedToCamera == true
            Group {
                if let collection, !isPinned {
                    LumaMainButton(title: footerTitle(for: collection, isPinned: false),
                                   icon: "pin.fill", height: 50) {
                        togglePin(collection)
                    }
                } else {
                    Button {
                        if let collection { togglePin(collection) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: collection == nil ? "pin" : "pin.slash")
                                .font(.system(size: 14, weight: .semibold))
                            Text(footerTitle(for: collection, isPinned: isPinned))
                                .font(.luma(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(Color.white.opacity(collection == nil ? 0.45 : 0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.lumaPress)
                    .disabled(collection == nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .padding(.top, 4)
        }
    }

    private func footerTitle(for collection: LUTCollection?, isPinned: Bool) -> String {
        guard let collection else { return "Select a collection to pin" }
        return isPinned
            ? "Unpin “\(collection.name)” from camera filmstrip"
            : "Pin “\(collection.name)” to camera filmstrip"
    }

    /// Arrive with the pinned collection (or the first one) already in hand so
    /// the pin action is live, not a dead placeholder.
    private func selectDefaultIfNeeded() {
        guard selectedID == nil else { return }
        selectedID = app.lutRepository.pinnedCollection?.id ?? groups.first?.collection.id
    }

    private func togglePin(_ collection: LUTCollection) {
        let isPinned = collection.pinnedToCamera == true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            app.lutRepository.setPinnedCollection(isPinned ? nil : collection.id)
        }
        LumaHaptics.shared.tap()
    }
}
