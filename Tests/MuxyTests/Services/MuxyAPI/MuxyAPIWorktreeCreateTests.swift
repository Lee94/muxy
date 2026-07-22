import Foundation
import Testing

@testable import Muxy

@Suite("MuxyAPI.Worktrees.create", .serialized)
@MainActor
struct MuxyAPIWorktreeCreateTests {
    @Test("create resolves the project's own context instead of the active workspace context")
    func createUsesProjectContext() async throws {
        let repo = try TempWorktreeGitRepo()
        defer { repo.cleanup() }
        try repo.commit(file: "a.txt", contents: "1", message: "init")

        let project = Project(name: "Repo", path: repo.path)
        let stores = makeStores(project: project)
        let previousContext = ActiveWorkspaceContext.shared.current
        ActiveWorkspaceContext.shared.update(.ssh(SSHDestination(host: "unreachable.invalid")))
        defer { ActiveWorkspaceContext.shared.update(previousContext) }

        let worktreePath = repo.siblingPath("feature-wt")
        let result = await MuxyAPI.Worktrees.create(
            CreateWorktreeRequest(
                name: "feature",
                branch: "feature",
                projectIdentifier: project.id.uuidString,
                requestedPath: worktreePath,
                createBranch: true,
                baseBranch: "main"
            ),
            appState: stores.appState,
            projectStore: stores.projectStore,
            worktreeStore: stores.worktreeStore,
            projectGroupStore: stores.projectGroupStore
        )

        guard case let .success(info) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(info.branch == "feature")
        #expect(FileManager.default.fileExists(atPath: worktreePath))
    }

    @Test("create without a group store falls back to local for local projects")
    func createFallsBackToLocal() async throws {
        let repo = try TempWorktreeGitRepo()
        defer { repo.cleanup() }
        try repo.commit(file: "a.txt", contents: "1", message: "init")

        let project = Project(name: "Repo", path: repo.path)
        let stores = makeStores(project: project)
        let previousContext = ActiveWorkspaceContext.shared.current
        ActiveWorkspaceContext.shared.update(.ssh(SSHDestination(host: "unreachable.invalid")))
        defer { ActiveWorkspaceContext.shared.update(previousContext) }

        let worktreePath = repo.siblingPath("local-wt")
        let result = await MuxyAPI.Worktrees.create(
            CreateWorktreeRequest(
                name: "local",
                branch: "local",
                projectIdentifier: project.id.uuidString,
                requestedPath: worktreePath,
                createBranch: true,
                baseBranch: ""
            ),
            appState: stores.appState,
            projectStore: stores.projectStore,
            worktreeStore: stores.worktreeStore
        )

        guard case .success = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: worktreePath))
    }

    private struct Stores {
        let appState: AppState
        let projectStore: ProjectStore
        let worktreeStore: WorktreeStore
        let projectGroupStore: ProjectGroupStore
    }

    private func makeStores(project: Project) -> Stores {
        let projectStore = ProjectStore(persistence: ProjectPersistenceMemoryStub())
        projectStore.add(project)
        let worktreeStore = WorktreeStore(
            persistence: WorktreePersistenceMemoryStub(),
            projects: [project]
        )
        let appState = AppState(
            selectionStore: SelectionStoreMemoryStub(),
            terminalViews: TerminalViewRemovingMemoryStub(),
            workspacePersistence: WorkspacePersistenceMemoryStub()
        )
        let projectGroupStore = ProjectGroupStore(
            persistence: ProjectGroupPersistenceStub(),
            remoteDeviceStore: RemoteDeviceStore(persistence: InMemoryRemoteDevicePersistence()),
            workspaceContextSink: InMemoryWorkspaceContextSink()
        )
        return Stores(
            appState: appState,
            projectStore: projectStore,
            worktreeStore: worktreeStore,
            projectGroupStore: projectGroupStore
        )
    }
}

private struct TempWorktreeGitRepo {
    let path: String
    private let parent: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muxy-api-worktree-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        parent = base.path
        path = base.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try run("init", "-q", "-b", "main")
        try run("config", "user.email", "test@example.com")
        try run("config", "user.name", "Test")
        try run("config", "commit.gpgsign", "false")
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: parent)
    }

    func siblingPath(_ name: String) -> String {
        URL(fileURLWithPath: parent).appendingPathComponent(name).path
    }

    func commit(file: String, contents: String, message: String) throws {
        let fileURL = URL(fileURLWithPath: path).appendingPathComponent(file)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try run("add", file)
        try run("commit", "-q", "-m", message)
    }

    private func run(_ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "TempWorktreeGitRepo",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]
            )
        }
    }
}

private final class ProjectPersistenceMemoryStub: ProjectPersisting {
    private var projects: [Project] = []
    func loadProjects() throws -> [Project] { projects }
    func saveProjects(_ projects: [Project]) throws { self.projects = projects }
}

private final class WorktreePersistenceMemoryStub: WorktreePersisting {
    private var storage: [UUID: [Worktree]] = [:]
    func loadWorktrees(projectID: UUID) throws -> [Worktree] { storage[projectID] ?? [] }
    func saveWorktrees(_ worktrees: [Worktree], projectID: UUID) throws { storage[projectID] = worktrees }
    func removeWorktrees(projectID: UUID) throws { storage.removeValue(forKey: projectID) }
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
