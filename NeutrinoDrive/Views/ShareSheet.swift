import SwiftUI

// MARK: - ShareSheet

/// Share a file or folder: add people by email, change or revoke their role, and create a
/// share link.
///
/// The E2EE re-wrap happens inside `SharingService.addPerson`. This view's job is to make the
/// *outcome* of that re-wrap legible — in particular the partial-success case, where the
/// permission was granted but the recipient cannot decrypt. A share sheet that reported that
/// as plain success would be actively misleading, since the file would appear shared and be
/// unopenable.
struct ShareSheet: View {

    // MARK: - Parameters

    let item: DriveItem

    // MARK: - Environment

    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @StateObject private var sharingService = SharingService()

    @State private var email = ""
    @State private var role: ShareRole = .viewer
    @State private var isAdding = false
    @State private var addError: String?
    /// Partial success: permission granted, DEK not re-wrapped. Held separately from
    /// `addError` because it is not a failure and must not read like one.
    @State private var keyWarning: String?
    @State private var shareLinkURL: URL?
    @State private var isCreatingLink = false
    @State private var didCopyLink = false
    @State private var pendingRevokeUserID: String?

    private var resourceType: ShareResourceType {
        item.type == .folder ? .folder : .file
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                addPeopleSection
                if let keyWarning { warningSection(keyWarning) }
                peopleSection
                linkSection
                if resourceType == .folder { folderCaveatSection }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                sharingService.authService = authService
                await sharingService.loadPermissions(resourceType: resourceType, resourceID: item.id)
            }
            .alert("Couldn't Share", isPresented: Binding(
                get: { addError != nil },
                set: { if !$0 { addError = nil } }
            )) {
                Button("OK") { addError = nil }
            } message: {
                Text(addError ?? "")
            }
            .confirmationDialog(
                "Remove access?",
                isPresented: Binding(
                    get: { pendingRevokeUserID != nil },
                    set: { if !$0 { pendingRevokeUserID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Access", role: .destructive) {
                    if let userID = pendingRevokeUserID { revoke(userID: userID) }
                    pendingRevokeUserID = nil
                }
                Button("Cancel", role: .cancel) { pendingRevokeUserID = nil }
            } message: {
                Text("They will no longer see \u{201C}\(item.name)\u{201D}. If they already opened it, they may still have a copy.")
            }
        }
    }

    // MARK: - Add People

    private var addPeopleSection: some View {
        Section {
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { add() }

            Picker("Role", selection: $role) {
                ForEach(ShareRole.assignable) { role in
                    Text(role.displayName).tag(role)
                }
            }

            Button {
                add()
            } label: {
                if isAdding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Sharing\u{2026}")
                    }
                } else {
                    Text("Share")
                }
            }
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
        } header: {
            Text("Add People")
        } footer: {
            if resourceType == .file {
                Text("This file's encryption key is re-wrapped for each person you add, on this device. The server never sees it unencrypted.")
            } else {
                Text("People you add can open this folder.")
            }
        }
    }

    private func warningSection(_ message: String) -> some View {
        Section {
            Label {
                Text(message)
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Dismiss") { keyWarning = nil }
                .font(.footnote)
        }
    }

    // MARK: - People

    @ViewBuilder
    private var peopleSection: some View {
        Section("People With Access") {
            if sharingService.isLoading && sharingService.permissions.isEmpty {
                HStack { ProgressView(); Text("Loading\u{2026}").foregroundStyle(.secondary) }
            } else if sharingService.permissions.isEmpty {
                Text("Not shared with anyone yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(sharingService.permissions) { permission in
                    permissionRow(permission)
                }
            }
        }
    }

    private func permissionRow(_ permission: SharePermission) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(permission.userName.isEmpty ? permission.userEmail : permission.userName)
                .font(.body)
            Text(permission.userEmail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .badge(permission.role.displayName)
        .swipeActions(edge: .trailing) {
            // Owners cannot be revoked — that is a transfer-ownership operation.
            if permission.role != .owner {
                Button(role: .destructive) {
                    pendingRevokeUserID = permission.userID
                } label: {
                    Label("Remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    // MARK: - Link

    private var linkSection: some View {
        Section {
            if let shareLinkURL {
                Text(shareLinkURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = shareLinkURL.absoluteString
                    didCopyLink = true
                } label: {
                    Label(didCopyLink ? "Copied" : "Copy Link",
                          systemImage: didCopyLink ? "checkmark" : "doc.on.doc")
                }
                Button(role: .destructive) {
                    removeLink()
                } label: {
                    Text("Remove Link")
                }
            } else {
                Button {
                    createLink()
                } label: {
                    if isCreatingLink {
                        HStack(spacing: 8) { ProgressView(); Text("Creating\u{2026}") }
                    } else {
                        Label("Create Share Link", systemImage: "link")
                    }
                }
                .disabled(isCreatingLink)
            }
        } header: {
            Text("Share Link")
        } footer: {
            // Stated rather than implied: a link grants access to ciphertext, and a link
            // recipient has no keypair to decrypt it with.
            Text("Anyone with the link can access this item on the server. Because files are end-to-end encrypted, a link recipient without their own Neutrino encryption key will not be able to read the contents.")
        }
    }

    private var folderCaveatSection: some View {
        Section {
            Text("Sharing a folder grants access to the folder itself. Files already inside it each need their own encryption key shared — open a file and share it directly so the recipient can read it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func add() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        isAdding = true
        keyWarning = nil
        Task {
            defer { isAdding = false }
            do {
                try await sharingService.addPerson(email: address,
                                                   role: role,
                                                   resourceType: resourceType,
                                                   resourceID: item.id)
                email = ""
            } catch let error as SharingError {
                if case .keyShareFailed = error {
                    // Partial success — the permission stands, so clear the field and warn
                    // rather than presenting this as a failed share.
                    email = ""
                    keyWarning = error.localizedDescription
                } else {
                    addError = error.localizedDescription
                }
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func revoke(userID: String) {
        Task {
            do {
                try await sharingService.revoke(userID: userID,
                                                resourceType: resourceType,
                                                resourceID: item.id)
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func createLink() {
        isCreatingLink = true
        Task {
            defer { isCreatingLink = false }
            do {
                let link = try await sharingService.createShareLink(resourceType: resourceType,
                                                                    resourceID: item.id)
                shareLinkURL = sharingService.shareLinkURL(link)
                didCopyLink = false
            } catch {
                addError = error.localizedDescription
            }
        }
    }

    private func removeLink() {
        Task {
            do {
                try await sharingService.deleteShareLink(resourceType: resourceType,
                                                         resourceID: item.id)
                shareLinkURL = nil
                didCopyLink = false
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ShareSheet(item: DriveItem(id: "f1", name: "Report.pdf", type: .file, parentID: nil,
                               size: 1024, modifiedAt: Date(), isTrashed: false,
                               isShared: false, mimeType: "application/pdf"))
        .environmentObject(AuthService())
}
