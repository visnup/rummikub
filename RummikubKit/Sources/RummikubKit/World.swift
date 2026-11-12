import CoreGraphics
import simd

/// The table as places, not frames: each tile seen with ARKit gets a point on the table plane, where its box's bottom
/// edge meets it, and every frame that sees a box there adds a read to it. A tile lying on the table has its near edge
/// there, and one standing on a rack its foot, which held still to 2–9 mm as the camera moved. So two of the same
/// tile are told apart by place, a pan builds a table bigger than any frame, and each tile is voted on by itself.
public struct World: Sendable {
  public struct Place: Sendable, Identifiable {
    public let id: Int
    /// In world coordinates, the mean over its sightings.
    public var point: SIMD3<Float>
    /// Its box's width on the table and height over width in the image, the means, to draw it from any pose.
    public var width: Float
    public var aspect: Float
    /// Summed odds for each tile it was read as.
    public var reads: [Tile: Float]
    /// Summed odds for each orientation of its likeliest tile.
    public var turns: [Float]
    public var seen = 1
    /// Frames in a row it should have shown in and didn't.
    public var missed = 0
    var rack: Float = 0, racked = 0

    public var tile: Tile { reads.max { ($0.value, $1.key.index) < ($1.value, $0.key.index) }!.key }
    /// Its reads as odds, for `Recognizer.valid`.
    public var odds: [Tile: Float] {
      let total = reads.values.reduce(0, +)
      return reads.mapValues { $0 / total }
    }
    /// Values' mean odds that it stands on a rack, or nil when no read said.
    public var onRack: Float? { racked > 0 ? rack / Float(racked) : nil }
    /// On the rack by Values' mean: in the first AR captures (#319–326) rack tiles' were .90 and up, and the table's
    /// .55 and under, nearest the rack.
    public var isRack: Bool { (onRack ?? 0) >= 0.75 }
    /// Seen in two frames, so a one-frame phantom box isn't a tile.
    public var sure: Bool { seen >= 2 }
  }

  public private(set) var places = [Place]()
  private var next = 0

  public init() {}

  /// A place is dropped after this many frames in a row in which it should have shown and didn't: picked up, or
  /// never a tile.
  static let forgotten = 3

  /// Adds a frame's reads, each to the place within half a tile of its point, nearest first, or to a new place. Places
  /// it should have seen and didn't are counted as missed, unless something covers them: a person, by `mask`, or
  /// another box, like a rack tile in front of the table. Returns each detection's place, nil where the pose has no
  /// table or the box's foot misses it.
  @discardableResult
  public mutating func add(_ detections: [Detection], pose: Pose, mask: Mask? = nil) -> [Int?] {
    guard pose.plane != nil else { return detections.map { _ in nil } }
    let feet = detections.map { d -> (point: SIMD3<Float>, width: Float)? in
      let box = d.frame
      guard let a = pose.ground(CGPoint(x: box.minX, y: box.maxY)), let b = pose.ground(CGPoint(x: box.maxX, y: box.maxY))
      else { return nil }
      return ((a + b) / 2, distance(a, b))
    }
    var pairs = [(distance: Float, detection: Int, place: Int)]()
    for (i, foot) in feet.enumerated() {
      guard let foot else { continue }
      for (j, place) in places.enumerated() {
        // Two of one tile never sit side by side in a meld, so the same read reaches further: a tile at an angle
        // moved its foot 14 mm between frames.
        let d = distance(foot.point, place.point)
        let reach = detections[i].tile == place.tile ? max(foot.width, place.width) * 0.75 : min(foot.width, place.width) / 2
        if d < reach { pairs.append((d, i, j)) }
      }
    }
    var matched = [Int?](repeating: nil, count: detections.count), taken = Set<Int>()
    for pair in pairs.sorted(by: { $0.distance < $1.distance })
    where matched[pair.detection] == nil && !taken.contains(pair.place) {
      matched[pair.detection] = pair.place
      taken.insert(pair.place)
    }

    for j in places.indices where !taken.contains(j) {
      guard let box = box(places[j], from: pose), shows(box, in: pose) else { continue }
      let area = box.width * box.height
      let covered = (mask?.covers(box, resolution: pose.resolution) ?? 0) >= 0.3
        || detections.contains { d in let o = d.frame.intersection(box); return !o.isNull && o.width * o.height >= area * 0.3 }
      if !covered { places[j].missed += 1 }
    }
    var ids = [Int?](repeating: nil, count: detections.count)
    for (i, d) in detections.enumerated() {
      guard let foot = feet[i] else { continue }
      let aspect = Float(d.frame.height / d.frame.width)
      if let j = matched[i] {
        var place = places[j]
        let n = Float(place.seen)
        place.point = (place.point * n + foot.point) / (n + 1)
        place.width = (place.width * n + foot.width) / (n + 1)
        place.aspect = (place.aspect * n + aspect) / (n + 1)
        place.seen += 1
        place.missed = 0
        Self.read(d, into: &place)
        places[j] = place
        ids[i] = place.id
      } else {
        var place = Place(id: next, point: foot.point, width: foot.width, aspect: aspect, reads: [:], turns: [0, 0, 0, 0])
        next += 1
        Self.read(d, into: &place)
        places.append(place)
        ids[i] = place.id
      }
    }
    places.removeAll { $0.missed >= Self.forgotten }
    // A second box on one tile in one frame starts a place beside it, as on #319's angled r4.
    for j in places.indices.reversed() {
      guard let k = places.indices.first(where: {
        $0 != j && places[$0].tile == places[j].tile && places[$0].seen >= places[j].seen
          && distance(places[$0].point, places[j].point) < max(places[$0].width, places[j].width) * 0.75
      }) else { continue }
      let gone = places.remove(at: j)
      let into = k < j ? k : k - 1
      for (tile, p) in gone.reads { places[into].reads[tile, default: 0] += p }
      for t in 0..<4 { places[into].turns[t] += gone.turns[t] }
      places[into].seen += gone.seen
      ids = ids.map { $0 == gone.id ? places[into].id : $0 }
    }
    return ids
  }

  private static func read(_ d: Detection, into place: inout Place) {
    if d.odds.isEmpty {
      place.reads[d.tile, default: 0] += 1
    } else {
      for (tile, p) in d.odds { place.reads[tile, default: 0] += p }
    }
    place.turns[d.turns % 4] += d.odds[d.tile] ?? 1
    if let rack = d.rack {
      place.rack += rack
      place.racked += 1
    }
  }

  /// Whether the finder should have found it from `pose`: in the image, a tile from its edges, and as big as the
  /// finder finds reliably (`Finder.smallest`).
  func shows(_ box: CGRect, in pose: Pose) -> Bool {
    let image = CGRect(origin: .zero, size: CGSize(width: pose.resolution.height, height: pose.resolution.width))
    return min(box.width, box.height) >= Finder.smallest
      && image.insetBy(dx: box.width, dy: box.height).contains(CGPoint(x: box.midX, y: box.maxY))
  }

  /// Where a person covers the image, from ARKit's segmentation: a small mask over the image as captured, nonzero for
  /// the person.
  public struct Mask: Sendable {
    public let width: Int, height: Int, bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
      self.width = width
      self.height = height
      self.bytes = bytes
    }

    /// A mask `k` times smaller each way, set wherever any pixel under it was.
    public func shrunk(by k: Int) -> Mask {
      let w = width / k, h = height / k
      return Mask(width: w, height: h, bytes: (0..<h).flatMap { y in
        (0..<w).map { x in (0..<k).contains { dy in (0..<k).contains { bytes[(y * k + dy) * width + x * k + $0] > 0 } } ? 255 : 0 }
      })
    }

    /// The share of a box in the upright image, of an image captured at `resolution`, that the person covers.
    public func covers(_ box: CGRect, resolution: CGSize) -> Double {
      // The upright image is the captured one turned a quarter clockwise: its x is the captured y from the bottom.
      let sx = Double(width) / resolution.width, sy = Double(height) / resolution.height
      let xs = max(0, Int(box.minY * sx))..<min(width, Int((box.maxY * sx).rounded(.up)))
      let ys = max(0, Int((resolution.height - box.maxX) * sy))..<min(height, Int(((resolution.height - box.minX) * sy).rounded(.up)))
      guard !xs.isEmpty, !ys.isEmpty else { return 0 }
      let on = ys.reduce(0) { n, y in n + xs.count { bytes[y * width + $0] > 0 } }
      return Double(on) / Double(xs.count * ys.count)
    }
  }

  /// Drops the rack's places or the table's, to scan that part again.
  public mutating func forget(rack: Bool) { places.removeAll { $0.isRack == rack } }

  /// Where a place shows from `pose`, in the upright image, or nil behind the camera.
  public func box(_ place: Place, from pose: Pose) -> CGRect? {
    let depth = -(pose.transform.inverse * SIMD4(place.point, 1)).z
    guard depth > 0, let foot = pose.project(place.point) else { return nil }
    let width = CGFloat(pose.intrinsics[0][0] * place.width / depth), height = width * CGFloat(place.aspect)
    return CGRect(x: foot.x - width / 2, y: foot.y - height, width: width, height: height)
  }

  /// Every sure place as a detection where it shows from `pose`, in view or not, so a part bigger than the frame reads
  /// whole.
  public func detections(from pose: Pose) -> [(place: Place, detection: Detection)] {
    places.filter(\.sure).compactMap { place in
      box(place, from: pose).map { frame in
        let turns = place.turns.indices.max { place.turns[$0] < place.turns[$1] }!
        return (place, Detection(tile: place.tile, frame: frame, turns: turns, odds: place.odds, rack: place.onRack))
      }
    }
  }
}
