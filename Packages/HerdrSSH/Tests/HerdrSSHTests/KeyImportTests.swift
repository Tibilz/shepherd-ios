import Foundation
import Testing
import HerdrKit
@testable import HerdrSSH

func keyFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct KeyImportTests {
    @Test func parsesEd25519() throws {
        let k = try SSHKeyImport.parse(try keyFixture("test_ed25519"), passphrase: nil)
        #expect(k.kind == .ed25519)
        #expect(k.fingerprintSHA256 == "SHA256:hXOau0/O+W/YD453WGrZbjWCXw48rvYfEXIWgK8tWy8")
        let pub = try keyFixture("test_ed25519.pub").split(separator: " ")
        #expect(k.publicKeyOpenSSH == "\(pub[0]) \(pub[1])")
        #expect(!k.isEncrypted)
    }

    @Test func parsesRSA() throws {
        let k = try SSHKeyImport.parse(try keyFixture("test_rsa"), passphrase: nil)
        #expect(k.kind == .rsa)
        #expect(k.fingerprintSHA256 == "SHA256:c2S1/8zsBpMwzJ5MyRBGccKtDiYBCMXhWlLSR2nuYTU")
    }

    @Test func rsaCarriesCompatibilityWarning() throws {
        let k = try SSHKeyImport.parse(try keyFixture("test_rsa"), passphrase: nil)
        #expect(k.warning?.contains("Ed25519") == true)
        #expect(try SSHKeyImport.parse(try keyFixture("test_ed25519"), passphrase: nil).warning == nil)
    }

    @Test func toleratesWhitespaceFromClipboard() throws {
        let pem = "\n  " + (try keyFixture("test_ed25519")).replacingOccurrences(of: "\n", with: "\r\n") + "  \n"
        let k = try SSHKeyImport.parse(pem, passphrase: nil)
        #expect(k.kind == .ed25519)
    }

    /// Autofill/typing can lose line breaks: body on one line, or breaks turned into spaces.
    @Test func singleLineKeyIsAccepted() throws {
        let pem = try keyFixture("test_ed25519")
        let lines = pem.split(separator: "\n").map(String.init)
        let oneLine = lines[0] + lines[1..<(lines.count - 1)].joined() + lines.last!
        let k = try SSHKeyImport.parse(oneLine, passphrase: nil)
        #expect(k.fingerprintSHA256 == "SHA256:hXOau0/O+W/YD453WGrZbjWCXw48rvYfEXIWgK8tWy8")
        _ = try SSHKeyImport.makeAuthentication(oneLine, kind: .ed25519, username: "u", passphrase: nil)
    }

    @Test func spaceSeparatedKeyIsAccepted() throws {
        let pem = try keyFixture("test_ed25519_pass").replacingOccurrences(of: "\n", with: " ")
        let k = try SSHKeyImport.parse(pem, passphrase: "geheim")
        #expect(k.fingerprintSHA256 == "SHA256:R8ctfqAvDj6dLcSFRFpuPbqwANZxHrPuBEgzXl8hJD4")
        _ = try SSHKeyImport.makeAuthentication(pem, kind: .ed25519, username: "u", passphrase: "geheim")
    }

    @Test func surroundingTextIsIgnored() throws {
        let pem = "Mein Key:\n" + (try keyFixture("test_rsa")) + "\nEnde"
        #expect(try SSHKeyImport.parse(pem, passphrase: nil).kind == .rsa)
    }

    @Test func encryptedNeedsPassphrase() throws {
        #expect(throws: KeyImportError.needsPassphrase) {
            _ = try SSHKeyImport.parse(try keyFixture("test_ed25519_pass"), passphrase: nil)
        }
    }

    @Test func encryptedWithPassphrase() throws {
        let k = try SSHKeyImport.parse(try keyFixture("test_ed25519_pass"), passphrase: "geheim")
        #expect(k.fingerprintSHA256 == "SHA256:R8ctfqAvDj6dLcSFRFpuPbqwANZxHrPuBEgzXl8hJD4")
        #expect(k.isEncrypted)
    }

    @Test func wrongPassphraseFails() throws {
        #expect(throws: KeyImportError.wrongPassphrase) {
            _ = try SSHKeyImport.parse(try keyFixture("test_ed25519_pass"), passphrase: "falsch")
        }
    }

    @Test func ecdsaIsUnsupported() throws {
        #expect(throws: KeyImportError.unsupported("ecdsa-sha2-nistp256")) {
            _ = try SSHKeyImport.parse(try keyFixture("test_ecdsa"), passphrase: nil)
        }
    }

    @Test func garbageIsInvalid() {
        #expect(throws: KeyImportError.invalid) { _ = try SSHKeyImport.parse("hallo welt", passphrase: nil) }
        #expect(throws: KeyImportError.invalid) {
            _ = try SSHKeyImport.parse("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----", passphrase: nil)
        }
    }

    @Test func publicKeyLineFingerprint() throws {
        let line = try keyFixture("test_rsa.pub")
        #expect(try SSHKeyImport.fingerprint(ofPublicKeyLine: line) == "SHA256:c2S1/8zsBpMwzJ5MyRBGccKtDiYBCMXhWlLSR2nuYTU")
    }
}
