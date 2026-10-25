import Foundation

/// Random, non-sequential identifier used for every record (plan §10.2: random IDs, owner checks elsewhere).
public struct EntityID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let raw: String
    public init() { raw = UUID().uuidString }
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }
    public static func < (a: EntityID, b: EntityID) -> Bool { a.raw < b.raw }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}

public enum ProtocolVersion { public static let current = 1 }
