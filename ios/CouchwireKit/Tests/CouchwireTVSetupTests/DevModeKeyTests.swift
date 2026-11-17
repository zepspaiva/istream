import Foundation
import Testing
@testable import CouchwireTVSetup

// Run on the Mac with:  cd ios/CouchwireKit && swift test
// Keys made for these tests only:  openssl genrsa -traditional -aes128 -passout pass:TEST42 1024  (and -des3).

private let aesKey = """
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,17BBD4FC4AE9003F2B1C8B3C52BFC13C

b98J/11UDpdXTxeq5QXPBFbLeNWsPidc+d4+LEB9nCI7t1lL/nlChpm4ZypRBsWl
PPJbM02yxTScDsIgrRCy1WRafprRTVWfLlIL5ZSk6BsxwCnyggccqHU+pGuZmuBR
udOHP7i2/geHJ2rHV7VwBXcgZHegMQzlb/Fye8QBAo8YJ/mKb2XNwjjV7v/VdLw3
ekkngN++RuPbS+ib5kx2BbkzJ3eYu6iDovQ9GXtursTqqw+e6uWIQGRPdDMOKja2
yBZ9xDu+zg5AvXAJT9z6x919ljiCTALL8/sYa8hBxX7vmRX/v/rcxo6blTikssaK
eORoeKhL2kl1DckXtr1JzqedR6hN/X5R1LUO0RyV4jzNmjnUNGRQdIUNS4JoJEgs
g+A2Y40VTxriZ1Uw1S8BAVweJM2v0cMrPqq37F87vrEzsKrmJRifgiZJWsvHdSuW
LmGhN07g11s8umpYDEqk8NCOLUtkiZhn6rDoOa6RXVhix3niAK2vtHnLFtwou+3V
oIa/EaEYQ6Y2TVpPBzc0mBIHoJ00kZM7AIn6zi8x2J7hvTaUL7smRKn+dnE50we4
BKrjE+GIHXENlwt89x1doCOpreZnoq3qloPb/+ldtPm9qOUJGCBwe84TOLGCbzj2
u8oWDmRrOU+KnN4pVYBOXMfQVNmIY44i6MTGTiZA7igcU+Y6T72yRwEq1xOYKgcP
uFsEmLmh1/nW+BbkNZTQRU3ZKIQ7EJ91a9sVSdijuX/oK8Ei9vdmofugzRZvKs31
MQKsuHCXLVRhi/JzE8y2w67HdTNtXnmJL+uF6ofNtd0v2qxko+Qiia/QfvCvqA/2
-----END RSA PRIVATE KEY-----
"""

private let aesPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCWblmy6f2sT+aLkquo+Uw51WRjmcny7xwdUzWZtXIP+QSrFKwxHpRgIZAIea0wgu3gR4veGnJqVhPvS9WsGi5YLNneoV8hmTjaJdF9bOaqHMOj8SewW9talYJhTLkv2uj2d+sL/TrndByE6W57O96S4lXtmg60J3YYaDcYWhP03Q=="

private let des3Key = """
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: DES-EDE3-CBC,0538E11FBD0C685F

VGBGGrA9+I5SuJXQSRX8LFLkyr4zHznVGJOtjHnwgqk5gaereqr4GiVjxYKeCm0W
zCxs8KwW+tdd0MohZX6AX/gV5tHhJfRWit5soHueApz0hJ75lnsWVIfP27Ly+nt7
IfgqLOQgVPMVDeE2vUYgn5R7Vlx7NXmfT0vWMm0/pJwBSes0pts+55xf63oYlw+Q
NnwNMKh69jvwaQAH2dI3XNygpsbgfobEYeVqu7IMsWPi67prFKEB6EAEvRdhzEc3
3k3Vm+vL/Nr/TVJfP6XeETY+I/WEW4Qo6/VQN2Li4VT7rCN7osVhecANA3CVX+mM
o8OMUPImhhiu51or2W0oCE7aZsfsy1I0PIXwxLkm5MpD8pOJyHNGLpSeBpSpVgR1
VeI63W7dl64j5+GlYS7tMHfTE5xGYVrnpxK9hAs2Btdh1u4zKAoi0FLRCyxAmJlX
WP3JTjZHRhOREUnKVNybhKjQEWocJHQPjZ5fP/7Va3vL61trSE+lwtonNGQhuZ2k
thdWcgJueZyer99/J6GraF/EvHF0Fopzyd1TVCiAw5eK8AZfr53rI/ewcIhNjYW9
ddbNFrnDQVu8iPVEIc/w5V9P+d6eI3d4lSp1qSdAtzYjJd5M7iQf0xewd+q4pqRc
LUXa7FpVUtGKucGXggYWS4jd6cZ+uVdPCVNFftctc6DHCRThxftSSJPms/sROY26
h3OB6Tu2nLT9lZJEceCIUrxUpyxywMUnYQHBotjE4JaGnOS9/sV+sZ8YofOd/xjN
U07PaXiyo7xuiWzQjYF5PJED78MZQKyTDNtLOVlshf0vSwSEcMDi/w==
-----END RSA PRIVATE KEY-----
"""

private let des3Public = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCa2RXNOOl4k+hhMKycoVHR7+DAaJwcjz6anPaoNkxeGXzk4/+nZZBkNaRVJCEgticzbckSyyje6gkiLwKJ92I/dcedS2pik3FsE2dkwjkbJSykdihz31QHLZwblG3IoCLe8cvGmCac63GOaDoGok4iQ4A5pe3FePcR7aDr/c+M7Q=="

@Test func unlocksAnAESKey() throws {
    let openSSH = try DevModeKey.unlock(aesKey, passphrase: "TEST42")
    #expect(openSSH.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
    _ = try DevModeKey.privateKey(openSSH)   // Citadel reads it back
    // Same key: the public half matches what ssh-keygen says for the original.
    let der = try DevModeKey.decrypt(Data(base64Encoded: body(aesKey))!,
                                     dekInfo: "AES-128-CBC,17BBD4FC4AE9003F2B1C8B3C52BFC13C", passphrase: "TEST42")
    #expect(PKCS1(der: der)?.publicKeyLine == aesPublic)
}

@Test func unlocksATripleDESKey() throws {
    let openSSH = try DevModeKey.unlock(des3Key, passphrase: "TEST42")
    _ = try DevModeKey.privateKey(openSSH)
    let der = try DevModeKey.decrypt(Data(base64Encoded: body(des3Key))!,
                                     dekInfo: "DES-EDE3-CBC,0538E11FBD0C685F", passphrase: "TEST42")
    #expect(PKCS1(der: der)?.publicKeyLine == des3Public)
}

@Test func wrongPassphraseSaysSo() {
    #expect(throws: DevModeKey.Failure.wrongPassphrase) { try DevModeKey.unlock(aesKey, passphrase: "test42") }
}

@Test func anUnlockedOpenSSHKeyPassesThrough() throws {
    let openSSH = try DevModeKey.unlock(aesKey, passphrase: "TEST42")
    #expect(try DevModeKey.unlock(openSSH, passphrase: "") == openSSH)
}

private func body(_ pem: String) -> String {
    pem.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("-----") && !$0.contains(":") }.joined()
}
