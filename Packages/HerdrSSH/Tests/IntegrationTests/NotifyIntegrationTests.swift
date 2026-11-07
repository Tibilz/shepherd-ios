import Foundation
import Testing
import HerdrKit
@testable import HerdrSSH

/// Installs herdr-notify into ~/.config/herdr-notify-it (separate from a real install), simulates a
/// blocked agent in the isolated session, checks the message arrived at ntfy, then uninstalls.
@Suite(.enabled(if: ITConfig.current != nil), .serialized)
struct NotifyIntegrationTests {
    func sh(_ shell: CitadelShell, _ script: String) async throws -> String {
        String(decoding: try await shell.exec(SocketCommand.login(script)).stdout, as: UTF8.self)
    }

    @Test func liveInstallBlockedReachesNtfyAndUninstallCleansUp() async throws {
        let c = ITConfig.current!
        let shell = try await c.connect()
        let client = HerdrClient(shell: shell, session: c.session)
        let status = try await client.connect()
        let pane = try #require(try await client.panes().first).paneId
        let installer = NotifyInstaller(shell: shell, baseDir: "~/.config/herdr-notify-it")
        let topic = NotifyConfig.randomTopic()
        let config = NotifyConfig(ntfyTopic: topic, socket: status.socket, serverId: UUID(), serverName: "IT")
        let herdr = "herdr --session \(c.session)"

        let crontabBefore = try await sh(shell, "crontab -l 2>/dev/null || true")
        var failure: Error?
        do {
            let mode = try await installer.install(config: config)
            #expect(mode == .background, "Testserver has neither linger nor cron")
            var running = false
            for _ in 0..<40 where !running {
                running = try await installer.status().running
                if !running { try await Task.sleep(for: .milliseconds(250)) }
            }
            #expect(running)
            // Wait until the daemon recorded its initial (silent) snapshot.
            var ready = false
            for _ in 0..<40 where !ready {
                ready = try await sh(shell, #"grep -c "bereit:" "$HOME/.config/herdr-notify-it/log" 2>/dev/null || true"#)
                    .trimmingCharacters(in: .whitespacesAndNewlines) != "0"
                if !ready { try await Task.sleep(for: .milliseconds(250)) }
            }
            #expect(ready)
            #expect(try await installer.readConfig() == config)

            _ = try await sh(shell, "\(herdr) pane report-agent --source it --agent claude --state working \(pane)")
            try await Task.sleep(for: .seconds(2))
            _ = try await sh(shell, "\(herdr) pane report-agent --source it --agent claude --state blocked \(pane)")

            var titles: [String] = []
            for _ in 0..<30 where titles.isEmpty {
                try await Task.sleep(for: .seconds(1))
                let lines = try await sh(shell, "curl -s -m 10 'https://ntfy.sh/\(topic)/json?poll=1&since=all'")
                titles = lines.split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["title"] as? String
                }
            }
            let log = try await sh(shell, #"cat "$HOME/.config/herdr-notify-it/log" 2>/dev/null"#)
            #expect(titles.contains { $0.hasSuffix("wartet auf Freigabe") }, "ntfy titles: \(titles)\nlog:\n\(log)")
        } catch {
            failure = error
        }

        _ = try? await sh(shell, "\(herdr) pane release-agent --source it --agent claude \(pane)")
        try await installer.uninstall()
        let after = try await installer.status()
        #expect(!after.installed)
        #expect(after.mode == .none)
        let leftovers = try await sh(shell, ##"ls -d "$HOME/.config/herdr-notify-it" 2>/dev/null; crontab -l 2>/dev/null | grep -c "# herdr-notify-it$" || true"##)
        #expect(leftovers.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        #expect(try await sh(shell, "crontab -l 2>/dev/null || true") == crontabBefore)
        await shell.close()
        if let failure { throw failure }
    }
}
