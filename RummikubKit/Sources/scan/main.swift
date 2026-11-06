import Foundation
import ImageIO
import RummikubKit
import UniformTypeIdentifiers

// Reads the tiles in a photo and writes the photo with what was read drawn over it.
let input = URL(filePath: CommandLine.arguments[1])
let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input as CFURL, nil)!, 0, nil)!
let start = Date()
let detections = Recognizer.tiles(in: image)
print(Date().timeIntervalSince(start), "s")
for meld in Recognizer.melds(detections) { print(meld.map(\.tile.description).joined(separator: " ")) }
let output = input.deletingPathExtension().appendingPathExtension("scan.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, Render.overlay(image, detections.map { .label($0.frame, $0.tile) }), nil)
CGImageDestinationFinalize(destination)
print(output.path)
