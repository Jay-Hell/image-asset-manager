import Foundation
import CryptoKit

extension Data {
    public var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
