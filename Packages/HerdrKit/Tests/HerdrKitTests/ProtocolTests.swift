import Foundation
import Testing
@testable import HerdrKit

/// Extracts the base64 payload embedded by SocketCommand and decodes the JSON request.
func decodeEmbeddedRequest(_ command: String) throws -> [String: Any] {
    let pattern = try NSRegularExpression(pattern: "printf %s ([A-Za-z0-9+/=]+) \\| base64 -d")
    let range = NSRange(command.startIndex..., in: command)
    let match = try #require(pattern.firstMatch(in: command, range: range))
    let b64 = String(command[Range(match.range(at: 1), in: command)!])
    let data = try #require(Data(base64Encoded: b64))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct ProtocolTests {
    @Test func encodesRequestLine() throws {
        let req = HerdrRequest(id: "app-1", method: "agent.prompt", params: ["target": .string("reviewer"), "text": .string("hi")])
        let line = try req.jsonLine()
        let s = try #require(String(data: line, encoding: .utf8))
        #expect(s.hasSuffix("\n"))
        #expect(s.contains("\"method\":\"agent.prompt\""))
        #expect(!s.dropLast().contains("\n"))
    }

    @Test func decodesErrorEnvelope() throws {
        let data = Data(#"{"id":"t2","error":{"code":"invalid_request","message":"x"}}"#.utf8)
        struct Any_: Decodable {}
        #expect(throws: HerdrError.server(code: "invalid_request", message: "x")) {
            _ = try HerdrResponse.decode(data, as: Any_.self)
        }
    }

    @Test func decodesResultEnvelope() throws {
        let data = Data(#"{"id":"t1","result":{"type":"subscription_started"}}"#.utf8)
        struct R: Decodable { let type: String }
        #expect(try HerdrResponse.decode(data, as: R.self).type == "subscription_started")
    }

    @Test func quoteHandlesSingleQuote() {
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.quote("plain") == "'plain'")
    }

    @Test func specialCharsSurviveBase64() throws {
        let text = "a'b\"c $HOME `x`\nä 🚀"
        let req = HerdrRequest(id: "app-2", method: "agent.prompt", params: ["target": .string("r"), "text": .string(text)])
        let cmd = try SocketCommand.oneShot(req, socket: "/home/u/.config/herdr/herdr.sock")
        let obj = try decodeEmbeddedRequest(cmd)
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["text"] as? String == text)
        #expect(!cmd.contains("$HOME"))
    }

    @Test func oneShotUsesSocketPath() throws {
        let req = HerdrRequest(id: "app-3", method: "workspace.list", params: [:])
        let cmd = try SocketCommand.oneShot(req, socket: "/home/my user/herdr.sock")
        #expect(cmd.hasSuffix("| nc -N -U '/home/my user/herdr.sock'"))
    }

    @Test func streamKeepsConnectionOpen() throws {
        let req = HerdrRequest(id: "app-4", method: "events.subscribe", params: [:])
        let cmd = try SocketCommand.stream(req, socket: "/s.sock", maxSeconds: 60)
        #expect(cmd.hasPrefix("exec timeout 60 sh -c "))
        #expect(cmd.contains("sleep 60"))
        #expect(cmd.contains("nc -U"))
    }

    @Test func quoteIfNeededKeepsSimpleWords() {
        #expect(ShellQuote.quoteIfNeeded("herdrapp-test") == "herdrapp-test")
        #expect(ShellQuote.quoteIfNeeded("a b") == "'a b'")
        #expect(ShellQuote.quoteIfNeeded("x;rm") == "'x;rm'")
        #expect(ShellQuote.quoteIfNeeded("") == "''")
    }

    @Test func loginWrapsInBash() {
        #expect(SocketCommand.login("herdr status") == "bash -lc 'herdr status'")
    }
}
