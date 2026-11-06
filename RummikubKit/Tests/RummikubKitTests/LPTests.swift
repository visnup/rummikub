import Testing

@testable import RummikubKit

@Test func linearProgram() {
  // max x + y with x + y + s = 4, x ≤ 3, y ≤ 3.
  var lp = LP(matrix: [1, 1, 1], b: [4], cost: [-1, -1, 0], lower: [0, 0, 0], upper: [3, 3, 10])
  let feasible = lp.solve()
  #expect(feasible)
  #expect(abs(lp.objective + 4) < 1e-9)
}

@Test func infeasible() {
  // x + y = 5 with x, y ≤ 2.
  var lp = LP(matrix: [1, 1], b: [5], cost: [0, 0], lower: [0, 0], upper: [2, 2])
  #expect(lp.minimize(integers: 2) == nil)
}

@Test func knapsack() {
  // max 5a + 4b + 3c with 2a + 3b + c + s = 5, binary: the relaxation takes c, a and two thirds of b.
  var lp = LP(matrix: [2, 3, 1, 1], b: [5], cost: [-5, -4, -3, 0], lower: [0, 0, 0, 0], upper: [1, 1, 1, 5])
  let x = lp.minimize(integers: 3)!
  #expect(x.prefix(3).map { $0.rounded() } == [1, 1, 0])
  #expect(abs(lp.objective + 32.0 / 3) < 1e-9)
}

@Test func rounding() {
  // max x + y with 2x + 2y + s = 3: 1.5 relaxed, 1 whole.
  var lp = LP(matrix: [2, 2, 1], b: [3], cost: [-1, -1, 0], lower: [0, 0, 0], upper: [5, 5, 3])
  let x = lp.minimize(integers: 2)!
  #expect(x[0].rounded() + x[1].rounded() == 1)
  #expect(abs(lp.objective + 1.5) < 1e-9)
}

@Test func warmStart() {
  // max x + 2y with x + y + s = 4, then again with y ≤ 1.
  var lp = LP(matrix: [1, 1, 1], b: [4], cost: [-1, -2, 0], lower: [0, 0, 0], upper: [4, 4, 4])
  #expect(lp.minimize(integers: 2)!.prefix(2).map { $0.rounded() } == [0, 4])
  lp.bound(1, 0, 1)
  #expect(lp.minimize(integers: 2)!.prefix(2).map { $0.rounded() } == [3, 1])
}
