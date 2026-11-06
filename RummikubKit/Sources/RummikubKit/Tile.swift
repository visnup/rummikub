public enum TileColor: Int, CaseIterable, Sendable {
  case black, blue, orange, red

  var letter: Character { ["k", "b", "o", "r"][rawValue] }
}

public enum Tile: Hashable, Sendable {
  case number(TileColor, Int)
  case joker

  /// 0..<52 for numbers by value, then color, and 52 for the joker.
  var index: Int {
    switch self {
    case .number(let color, let value): (value - 1) * 4 + color.rawValue
    case .joker: 52
    }
  }

  /// `k5`, `b13`, `o1`, `r7` or `j`.
  public init?(_ string: some StringProtocol) {
    if string == "j" { self = .joker; return }
    guard let first = string.first,
      let color = TileColor.allCases.first(where: { $0.letter == first }),
      let value = Int(string.dropFirst()), (1...13).contains(value)
    else { return nil }
    self = .number(color, value)
  }

  /// Space-separated tiles, as in `r5 r6 j`.
  public static func parse(_ string: String) -> [Tile] {
    string.split(separator: " ").map { Tile($0)! }
  }

  public var value: Int? {
    if case .number(_, let value) = self { value } else { nil }
  }

  public var color: TileColor? {
    if case .number(let color, _) = self { color } else { nil }
  }
}

extension Tile: CustomStringConvertible {
  public var description: String {
    switch self {
    case .number(let color, let value): "\(color.letter)\(value)"
    case .joker: "j"
    }
  }
}

/// How many of each tile, indexed by `Tile.index`.
typealias Counts = SIMD64<UInt8>

extension Counts {
  init(_ tiles: some Sequence<Tile>) {
    self.init()
    for tile in tiles { self[tile.index] += 1 }
  }

  var total: Int { Int(wrappedSum()) }

  var first: Int? { (0..<53).first { self[$0] > 0 } }

  func overlap(_ other: Counts) -> Int { pointwiseMin(self, other).total }
}
