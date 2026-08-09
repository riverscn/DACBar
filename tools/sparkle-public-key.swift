#!/usr/bin/env swift
import CryptoKit
import Foundation

let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let seed = Data(base64Encoded: input), seed.count == 32 else {
    FileHandle.standardError.write(Data("Expected a Base64-encoded 32-byte Ed25519 seed.\n".utf8))
    exit(1)
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("Invalid Ed25519 seed: \(error)\n".utf8))
    exit(1)
}
