import CryptoKit
import Foundation

// The raw Ed25519 private key lives outside the checkout. Only the public key ships in the app.
let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    fatalError("Usage: swift scripts/sign-update.swift --generate KEY | KEY ZIP PUBLIC_KEY")
}
if arguments.count == 3 && arguments[1] == "--generate" {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: URL(fileURLWithPath: arguments[2]), options: .withoutOverwriting)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else if arguments.count == 4 {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
    guard key.publicKey.rawRepresentation.base64EncodedString() == arguments[3] else {
        fatalError("The signing key does not match the public key embedded in the app.")
    }
    let zip = URL(fileURLWithPath: arguments[2])
    try key.signature(for: Data(contentsOf: zip)).write(to: zip.appendingPathExtension("sig"), options: .atomic)
} else {
    fatalError("Invalid arguments")
}
