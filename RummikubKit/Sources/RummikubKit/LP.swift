import Accelerate

/// A linear program: minimize `cost · x` subject to `A x = b` and `lower ≤ x ≤ upper`, every bound finite.
///
/// Solved by the revised dual simplex method with bounded variables, keeping B⁻¹ dense and A by sparse columns.
/// Finite bounds make any basis dual feasible once each nonbasic variable sits at the bound its reduced cost favors,
/// so it starts from a basis of artificial variables and warm starts after a bound changes.
struct LP {
  static let tolerance = 1e-9

  let rows: Int
  let columns: Int
  let cost: [Double]
  /// Column j of A is `entries[start[j]..<start[j + 1]]`.
  let start: [Int]
  let entries: [(row: Int, value: Double)]
  /// The same entries by row.
  let byRow: [[(column: Int, value: Double)]]
  /// Bounds for every column, then each row's artificial variable, fixed at zero. An artificial variable has no
  /// column: once it leaves the basis it never comes back.
  var lower: [Double]
  var upper: [Double]
  var x: [Double]
  /// The variable basic in each row.
  var basis: [Int]
  var basic: [Bool]
  /// B⁻¹, row-major.
  var inverse: [Double]
  var reduced: [Double]

  /// `matrix` is A, row-major.
  init(matrix: [Double], b: [Double], cost: [Double], lower: [Double], upper: [Double]) {
    rows = b.count
    columns = cost.count
    self.cost = cost
    var start = [0]
    var entries = [(row: Int, value: Double)]()
    var byRow = Array(repeating: [(column: Int, value: Double)](), count: rows)
    for j in 0..<columns {
      for i in 0..<rows where matrix[i * columns + j] != 0 {
        entries.append((i, matrix[i * columns + j]))
        byRow[i].append((j, matrix[i * columns + j]))
      }
      start.append(entries.count)
    }
    self.start = start
    self.entries = entries
    self.byRow = byRow
    self.lower = lower + Array(repeating: 0, count: rows)
    self.upper = upper + Array(repeating: 0, count: rows)
    x = cost.indices.map { cost[$0] < 0 ? upper[$0] : lower[$0] } + b
    for j in 0..<columns {
      for (i, value) in entries[start[j]..<start[j + 1]] { x[columns + i] -= value * x[j] }
    }
    basis = Array(columns..<columns + rows)
    basic = Array(repeating: false, count: columns)
    let m = rows
    inverse = (0..<m * m).map { $0 % (m + 1) == 0 ? 1 : 0 }
    reduced = cost
  }

  var objective: Double { zip(cost, x).reduce(0) { $0 + $1.0 * $1.1 } }

  /// B⁻¹ times column `j` of A.
  func column(_ j: Int) -> [Double] {
    (0..<rows).map { i in entries[start[j]..<start[j + 1]].reduce(0) { $0 + inverse[i * rows + $1.row] * $1.value } }
  }

  /// Pivots until every basic variable is within its bounds. Returns false when there's no feasible solution.
  mutating func solve() -> Bool {
    let m = rows
    var alpha = [Double](repeating: 0, count: columns)
    while true {
      var r = -1
      var worst = Self.tolerance
      for i in 0..<m {
        let k = basis[i]
        let violation = max(lower[k] - x[k], x[k] - upper[k])
        if violation > worst { (r, worst) = (i, violation) }
      }
      guard r >= 0 else { return true }
      let leaving = basis[r]
      let below = x[leaving] < lower[leaving]
      alpha.withUnsafeMutableBufferPointer { alpha in
        alpha.update(repeating: 0)
        for i in 0..<m where inverse[r * m + i] != 0 {
          let rho = inverse[r * m + i]
          byRow[i].withUnsafeBufferPointer {
            for (j, value) in $0 { alpha[j] += rho * value }
          }
        }
      }
      var q = -1
      var best = Double.infinity
      var size = 0.0
      for j in 0..<columns where !basic[j] && lower[j] < upper[j] {
        let a = below ? -alpha[j] : alpha[j]
        guard x[j] == upper[j] ? a < -Self.tolerance : a > Self.tolerance else { continue }
        let ratio = abs(reduced[j] / a)
        if ratio < best - Self.tolerance || (ratio < best + Self.tolerance && abs(a) > size) {
          (q, best, size) = (j, ratio, abs(a))
        }
      }
      guard q >= 0 else { return false }
      let u = column(q)
      let step = (x[leaving] - (below ? lower[leaving] : upper[leaving])) / u[r]
      for i in 0..<m where i != r { x[basis[i]] -= u[i] * step }
      x[q] += step
      x[leaving] = below ? lower[leaving] : upper[leaving]
      let ratio = reduced[q] / u[r]
      for j in 0..<columns where !basic[j] { reduced[j] -= ratio * alpha[j] }
      reduced[q] = 0
      if leaving < columns {
        reduced[leaving] = -ratio
        basic[leaving] = false
      }
      basis[r] = q
      basic[q] = true
      inverse.withUnsafeMutableBufferPointer { inverse in
        let pivot = inverse.baseAddress! + r * m
        var scale = 1 / u[r]
        vDSP_vsmulD(pivot, 1, &scale, pivot, 1, vDSP_Length(m))
        for i in 0..<m where i != r && u[i] != 0 {
          let row = inverse.baseAddress! + i * m
          scale = -u[i]
          vDSP_vsmaD(pivot, 1, &scale, row, 1, row, 1, vDSP_Length(m))
        }
      }
    }
  }

  /// Moves column `j`'s bounds. A nonbasic variable moves to the bound its reduced cost favors.
  mutating func bound(_ j: Int, _ lower: Double, _ upper: Double) {
    self.lower[j] = lower
    self.upper[j] = upper
    guard !basic[j] else { return }
    let value =
      reduced[j] < -Self.tolerance ? upper : reduced[j] > Self.tolerance ? lower : x[j] == self.upper[j] ? upper : lower
    let delta = value - x[j]
    guard delta != 0 else { return }
    x[j] = value
    for (i, u) in column(j).enumerated() { x[basis[i]] -= u * delta }
  }

  /// The best solution whose first `integers` columns are whole, by depth-first branch and bound, or nil if there's
  /// none. The objective must be whole at every such solution. Branches on the first `leading` columns before the
  /// most fractional of the rest, rounding up first. Leaves the relaxation solved, to warm start the next call after
  /// a bound changes.
  mutating func minimize(integers: Int, leading: Int = 0) -> [Double]? {
    guard solve() else { return nil }
    var best: (objective: Double, x: [Double])?
    func visit(_ lp: inout LP) {
      guard lp.solve() else { return }
      let objective = lp.objective
      if let best, objective > best.objective - 1 + 1e-6 { return }
      let fractional =
        (0..<leading).first { lp.x[$0].fractionalness > 1e-6 }
        ?? (0..<integers).max { lp.x[$0].fractionalness < lp.x[$1].fractionalness }
      guard let j = fractional, lp.x[j].fractionalness > 1e-6 else {
        best = (objective, lp.x)
        return
      }
      let value = lp.x[j]
      var down = lp
      lp.bound(j, value.rounded(.up), lp.upper[j])
      visit(&lp)
      down.bound(j, down.lower[j], value.rounded(.down))
      visit(&down)
    }
    var root = self
    visit(&root)
    return best?.x
  }
}

extension Double {
  fileprivate var fractionalness: Double { abs(self - rounded()) }
}
