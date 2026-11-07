import Foundation
import Testing
@testable import ReclaimCore

@Suite struct MemoryTests {
    @Test func readsSystemStats() throws {
        let stats = try #require(MemoryMonitor.stats())
        #expect(stats.total == Int64(ProcessInfo.processInfo.physicalMemory))
        #expect(stats.appMemory > 0)
        #expect(stats.wired > 0)
        #expect(stats.used <= stats.total)
        #expect((0...1).contains(stats.usedFraction))
    }

    @Test func derivedValues() {
        let stats = MemoryStats(
            total: 16_000, appMemory: 5_000, wired: 2_000, compressed: 1_000, cachedFiles: 6_000,
            swapUsed: 0, swapTotal: 0, pressure: .normal
        )
        #expect(stats.used == 8_000)
        #expect(stats.free == 2_000)
        #expect(stats.available == 8_000)
        #expect(stats.usedFraction == 0.5)
    }

    @Test func mapsKernelPressureLevels() {
        #expect(MemoryMonitor.pressureLevel(fromKernelValue: 1) == .normal)
        #expect(MemoryMonitor.pressureLevel(fromKernelValue: 2) == .warning)
        #expect(MemoryMonitor.pressureLevel(fromKernelValue: 4) == .critical)
        #expect(MemoryMonitor.pressureLevel(fromKernelValue: 0) == .normal)
    }

    @Test func groupsHelpersUnderTheirOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let group = MemoryMonitor.groupKey(forExecutable: helper)
        #expect(group.key == "/Applications/Google Chrome.app")
        #expect(group.name == "Google Chrome")
        #expect(group.bundle?.lastPathComponent == "Google Chrome.app")

        let tool = MemoryMonitor.groupKey(forExecutable: "/opt/homebrew/bin/node")
        #expect(tool.key == "/opt/homebrew/bin/node")
        #expect(tool.name == "node")
        #expect(tool.bundle == nil)
    }

    @Test func findsOwnProcess() {
        let groups = MemoryMonitor.processGroups()
        #expect(groups.contains { $0.pids.contains(getpid()) })
        #expect(zip(groups, groups.dropFirst()).allSatisfy { $0.memory >= $1.memory })
    }

    @Test func refusesToTerminateSystemProcesses() {
        let dock = ProcessGroup(id: "/System/Library/CoreServices/Dock.app", name: "Dock", bundleURL: nil, pids: [1], memory: 1)
        #expect(dock.isSystem)
        #expect(throws: UninstallError.self) { try MemoryMonitor.terminate(dock) }

        let node = ProcessGroup(id: "/opt/homebrew/bin/node", name: "node", bundleURL: nil, pids: [], memory: 1)
        #expect(!node.isSystem)
    }
}
