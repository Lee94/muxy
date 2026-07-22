import Foundation
import Testing

@testable import Muxy

@Suite("ExtensionBridgeShared.activeWorkspaceContext")
@MainActor
struct ExtensionBridgeWorkspaceContextTests {
    @Test("resolves the ssh context of an active device-backed remote project while the global context is local")
    func deviceBackedRemoteProjectResolvesSSH() {
        let stores = makeStores()
        let device = stores.remoteDeviceStore.add(name: "server", ssh: SSHWorkspaceData(host: "server.example"))
        let project = Project(name: "Remote", path: "/home/user/repo", remoteDeviceID: device.id)
        stores.projectStore.add(project)
        stores.appState.activeProjectID = project.id

        let previousContext = ActiveWorkspaceContext.shared.current
        ActiveWorkspaceContext.shared.update(.local)
        defer { ActiveWorkspaceContext.shared.update(previousContext) }

        let context = ExtensionBridgeShared.activeWorkspaceContext(
            appState: stores.appState,
            projectStore: stores.projectStore,
            projectGroupStore: stores.projectGroupStore
        )

        #expect(context == .ssh(device.destination))
    }

    @Test("resolves local context for an active local project while the global context is remote")
    func localProjectResolvesLocal() {
        let stores = makeStores()
        let project = Project(name: "Local", path: "/tmp/repo")
        stores.projectStore.add(project)
        stores.appState.activeProjectID = project.id

        let previousContext = ActiveWorkspaceContext.shared.current
        ActiveWorkspaceContext.shared.update(.ssh(SSHDestination(host: "unreachable.invalid")))
        defer { ActiveWorkspaceContext.shared.update(previousContext) }

        let context = ExtensionBridgeShared.activeWorkspaceContext(
            appState: stores.appState,
            projectStore: stores.projectStore,
            projectGroupStore: stores.projectGroupStore
        )

        #expect(context == .local)
    }

    @Test("returns nil without an active project")
    func missingActiveProjectReturnsNil() {
        let stores = makeStores()

        let context = ExtensionBridgeShared.activeWorkspaceContext(
            appState: stores.appState,
            projectStore: stores.projectStore,
            projectGroupStore: stores.projectGroupStore
        )

        #expect(context == nil)
    }

    private struct Stores {
        let appState: AppState
        let projectStore: ProjectStore
        let projectGroupStore: ProjectGroupStore
        let remoteDeviceStore: RemoteDeviceStore
    }

    private func makeStores() -> Stores {
        let projectStore = ProjectStore(persistence: ProjectPersistenceMemoryStub())
        let appState = AppState(
            selectionStore: SelectionStoreMemoryStub(),
            terminalViews: TerminalViewRemovingMemoryStub(),
            workspacePersistence: WorkspacePersistenceMemoryStub()
        )
        let remoteDeviceStore = RemoteDeviceStore(persistence: InMemoryRemoteDevicePersistence())
        let projectGroupStore = ProjectGroupStore(
            persistence: ProjectGroupPersistenceStub(),
            remoteDeviceStore: remoteDeviceStore,
            workspaceContextSink: InMemoryWorkspaceContextSink()
        )
        return Stores(
            appState: appState,
            projectStore: projectStore,
            projectGroupStore: projectGroupStore,
            remoteDeviceStore: remoteDeviceStore
        )
    }
}

private final class ProjectPersistenceMemoryStub: ProjectPersisting {
    private var projects: [Project] = []
    func loadProjects() throws -> [Project] { projects }
    func saveProjects(_ projects: [Project]) throws { self.projects = projects }
}

private final class WorkspacePersistenceMemoryStub: WorkspacePersisting {
    private var snapshots: [WorkspaceSnapshot] = []
    func loadWorkspaces() throws -> [WorkspaceSnapshot] { snapshots }
    func saveWorkspaces(_ workspaces: [WorkspaceSnapshot]) throws { snapshots = workspaces }
}

@MainActor
private final class SelectionStoreMemoryStub: ActiveProjectSelectionStoring {
    private var activeProjectID: UUID?
    private var activeWorktreeIDs: [UUID: UUID] = [:]
    func loadActiveProjectID() -> UUID? { activeProjectID }
    func saveActiveProjectID(_ id: UUID?) { activeProjectID = id }
    func loadActiveWorktreeIDs() -> [UUID: UUID] { activeWorktreeIDs }
    func saveActiveWorktreeIDs(_ ids: [UUID: UUID]) { activeWorktreeIDs = ids }
}

@MainActor
private final class TerminalViewRemovingMemoryStub: TerminalViewRemoving {
    func removeView(for paneID: UUID) {}
    func needsConfirmQuit(for paneID: UUID) -> Bool { false }
}
