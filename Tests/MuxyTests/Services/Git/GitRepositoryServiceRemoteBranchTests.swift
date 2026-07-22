import Foundation
import Testing

@testable import Muxy

@Suite("GitRepositoryService remote branches")
struct GitRepositoryServiceRemoteBranchTests {
    @Test("groups remote tracking refs by remote and filters HEAD")
    func groupsRemoteTrackingRefsByRemote() {
        let refs = """
        refs/remotes/origin/HEAD
        refs/remotes/origin/main
        refs/remotes/origin/feature/login
        refs/remotes/upstream/develop
        """
        let groups = GitRepositoryService.remoteBranchGroups(refsOutput: refs, remotesOutput: "origin\nupstream\n")
        #expect(groups == [
            GitRepositoryService.RemoteBranchGroup(remote: "origin", branches: ["feature/login", "main"]),
            GitRepositoryService.RemoteBranchGroup(remote: "upstream", branches: ["develop"]),
        ])
    }

    @Test("matches the longest remote prefix")
    func matchesLongestRemotePrefix() {
        let refs = """
        refs/remotes/origin/main
        refs/remotes/origin/fork/topic
        """
        let groups = GitRepositoryService.remoteBranchGroups(refsOutput: refs, remotesOutput: "origin\norigin/fork\n")
        #expect(groups == [
            GitRepositoryService.RemoteBranchGroup(remote: "origin", branches: ["main"]),
            GitRepositoryService.RemoteBranchGroup(remote: "origin/fork", branches: ["topic"]),
        ])
    }

    @Test("ignores refs that do not belong to a known remote")
    func ignoresRefsWithoutKnownRemote() {
        let groups = GitRepositoryService.remoteBranchGroups(
            refsOutput: "refs/remotes/other/main\nrefs/heads/main\n",
            remotesOutput: "origin\n"
        )
        #expect(groups.isEmpty)
    }

    @Test("lists remote tracking branches from a repository")
    func listsRemoteTrackingBranchesFromRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remotePath = root.appendingPathComponent("remote", isDirectory: true).path
        let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: remotePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)

        _ = try await GitProcessRunner.runGit(repoPath: remotePath, arguments: ["init", "--initial-branch=main"])
        _ = try await GitProcessRunner.runGit(
            repoPath: remotePath,
            arguments: [
                "-c", "user.name=Muxy", "-c", "user.email=muxy@test",
                "commit", "--allow-empty", "-m", "init",
            ]
        )
        _ = try await GitProcessRunner.runGit(repoPath: remotePath, arguments: ["branch", "feature/login"])

        _ = try await GitProcessRunner.runGit(repoPath: repoPath, arguments: ["init"])
        _ = try await GitProcessRunner.runGit(repoPath: repoPath, arguments: ["remote", "add", "origin", remotePath])
        _ = try await GitProcessRunner.runGit(repoPath: repoPath, arguments: ["fetch", "origin"])

        let groups = try await GitRepositoryService().listRemoteTrackingBranches(repoPath: repoPath)
        #expect(groups == [
            GitRepositoryService.RemoteBranchGroup(remote: "origin", branches: ["feature/login", "main"]),
        ])
    }
}
