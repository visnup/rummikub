import RummikubKit
import Foundation
let args = CommandLine.arguments
let table = args[1].split(separator: ",").map { Tile.parse(String($0)) }
let rack = Tile.parse(args[2])
let start = Date()
let plays = solve(table: table, rack: rack)
print(Date().timeIntervalSince(start), plays.map { [$0.placed, $0.moved] })
