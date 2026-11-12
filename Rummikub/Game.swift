import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Observation
import RummikubKit
import simd
import UniformTypeIdentifiers

/// What the camera has read of the table and rack, the plays for them, and the step being shown.
@Observable final class Game {
  enum Looking: String, CaseIterable {
    case table, rack
  }

  /// What a capture writes as its truth: what was read, to be corrected by hand, or a layout set out on purpose.
  enum Layout: String, CaseIterable {
    case read = "As read", fullSet = "Full set", empty = "No tiles"

    var melds: [String]? {
      switch self {
      case .read: nil
      case .fullSet: "kkbboorr".map { color in (1...13).map { "\(color)\($0)" }.joined(separator: " ") } + ["j j"]
      case .empty: []
      }
    }
  }

  var looking = Looking.table
  var layout = Layout.read
  /// What's around the tiles, like "lamp glare, wood", saved with each capture.
  /// Single-word tags, kept across launches, that `check` reports by.
  var notes = UserDefaults.standard.string(forKey: "notes") ?? "" {
    didSet { UserDefaults.standard.set(notes, forKey: "notes") }
  }
  var gravity: [Double]?
  /// How long the last frame took to read: classifying the finder's boxes.
  var readTime = Duration.zero
  /// How long the finder took on the last frame.
  var findTime = Duration.zero
  /// The tiles the finder saw in the last frame.
  var boxes = [CGRect]()
  /// Loaded off the main thread, since a cold launch takes seconds to load them. Frames before then are skipped.
  private var models: Models?
  private var finder: Finder? { models?.finder }
  private var values: Classifier? { models?.values }
  private var lookingModel: Classifier? { models?.looking }

  var loading: Bool { models == nil }
  /// When the models started loading, and how long they took last launch, for the progress shown meanwhile.
  let loadStart = Date.now
  let loadEstimate = UserDefaults.standard.object(forKey: "loadTime") as? Double ?? 7

  private nonisolated struct Models: Sendable {
    let finder: Finder?
    /// What reads the finder's boxes: each tile and its orientation.
    let values: Classifier?
    /// Whether a frame shows a rack or the table, from the whole picture: tilt alone can't say, since racks were shot
    /// at 24–48° and tables from 35° up. On held-out frames it got 21 of 24, two of them judgment calls.
    let looking: Classifier?
  }

  init() {
    Task {
      let finder = Task.detached {
        Game.model("Tiles").flatMap { try? Finder(model: $0) }.map {
          var finder = $0
          finder.enough = 80
          return finder
        }
      }
      let values = Task.detached { Game.model("Values").flatMap { try? Classifier(model: $0) } }
      let looking = Task.detached { Game.model("Looking").flatMap { try? Classifier(model: $0) } }
      models = Models(finder: await finder.value, values: await values.value, looking: await looking.value)
      let time = Date.now.timeIntervalSince(loadStart)
      UserDefaults.standard.set(time, forKey: "loadTime")
      _ = try? timing?.seekToEnd()
      try? timing?.write(contentsOf: Data("\(Date.now.timeIntervalSince1970),load,0,\(Int(time * 1000)),0,0\n".utf8))
    }
  }

  private nonisolated static func model(_ name: String) -> MLModel? {
    let configuration = MLModelConfiguration()
    #if targetEnvironment(simulator)
      // Else Vision can't create an inference context.
      configuration.computeUnits = .cpuOnly
    #endif
    return Bundle.main.url(forResource: name, withExtension: "mlmodelc").flatMap {
      try? MLModel(contentsOf: $0, configuration: configuration)
    }
  }
  /// How far the camera points below the horizon, in degrees. Looking down at the table it's steep; at the rack,
  /// nearly level. Below 30° and above 55° it decides; between, the Looking model does, or without it a cutoff at
  /// 45°. A pick by hand holds until that part locks.
  var tilt: Double? {
    didSet {
      guard let tilt, picked == nil else { return }
      if tilt > 55 {
        looking = .table
      } else if tilt < 30 || tilt < 45 && lookingModel == nil {
        looking = .rack
      }
    }
  }
  /// What was picked by hand, until it locks.
  private var picked: Looking?

  func pick(_ looking: Looking) {
    self.looking = looking
    picked = looking
  }
  /// The last frame read, and what was read in it.
  var frame: CGImage?
  var detections = [Detection]()
  var scene = Scene(table: [], rack: [])
  var plays = [Play]()
  var choice = 0
  /// Whether the player has laid down their first 30 points, after which they may play on the table.
  var opened = true {
    didSet { if opened != oldValue, !locked.isEmpty { Task { await solve() } } }
  }
  /// The step shown, or nil before starting a play. While stepping, new readings don't re-solve.
  var step: Int?
  /// Every frame's timing, a file a launch in Documents/timing, for `make timing`.
  private let timing: FileHandle? = {
    let directory = URL.documentsDirectory.appending(path: "timing")
    let url = directory.appending(path: Date.now.formatted(.iso8601) + ".csv")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: Data("time,looking,read_ms,find_ms,readings,boxes\n".utf8))
    else { return nil }
    return try? FileHandle(forWritingTo: url)
  }()

  var play: Play? { plays.indices.contains(choice) ? plays[choice] : nil }

  /// ARKit's frame, when it's running the camera, and each box's size on the table it found (`Pose.footprint`).
  var ar: Frame?
  var footprints = [SIMD2<Float>?]()

  /// Reads a frame, or takes `read`, a recording's reads of it, as the simulator replays one.
  func see(_ image: CGImage, ar: Frame? = nil, read: [Detection]? = nil) async {
    guard models != nil else { return }
    // Once locked, frames only watch for changes, so a second apart is enough and the phone stays cooler; while
    // stepping through a play, every frame, to follow each move.
    if locked.contains(looking), step == nil, Date.now.timeIntervalSince(lastSeen) < 1 { return }
    lastSeen = .now
    // Only where tilt can't say: below 30° it's always been a rack, above 55° a table.
    if picked == nil, read == nil, let lookingModel, (30...55).contains(tilt ?? 40),
      let (label, confidence) = await Task.detached(operation: { try? lookingModel.label(of: image) }).value,
      confidence >= 0.8, let seen = Looking(rawValue: label)
    {
      looking = seen
    }
    // With a table plane, every read goes to the world table, which says what's on the rack by place.
    let pose = ar?.pose.flatMap { $0.plane == nil ? nil : $0 }
    if ar?.pose == nil { world = World() }
    let finder = finder, classifier = values, rack = looking == .rack && pose == nil
    // The finder's boxes read by Values.
    let (found, boxes, findTime, time) = await Task.detached {
      if let read { return (read, Optional(read.map(\.frame)), Duration.zero, Duration.zero) }
      let clock = ContinuousClock()
      var boxes: [CGRect]?
      let findTime = clock.measure { boxes = try? finder?.tiles(in: image) }
      if rack { boxes = boxes.map(Finder.nearest) }
      var found = [Detection]()
      let time = clock.measure { found = boxes.flatMap { try? classifier?.tiles(in: image, boxes: $0) } ?? [] }
      // At the rack, Values says which tiles lie on the table behind it, where `nearest` couldn't.
      if rack { found = found.filter { ($0.rack ?? 1) >= 0.5 } }
      return (found, boxes, findTime, time)
    }.value
    frame = image
    readTime = time
    self.findTime = findTime
    self.boxes = boxes ?? []
    self.ar = ar
    footprints = ar?.pose.map { pose in self.boxes.map(pose.footprint) } ?? []
    detections = found
    if ar == nil, recording != nil { stopRecording() }
    _ = try? timing?.seekToEnd()
    try? timing?.write(contentsOf: Data(
      "\(Date.now.timeIntervalSince1970),\(looking),\(Int(time / .milliseconds(1))),\(Int(findTime / .milliseconds(1))),\(found.count),\(boxes?.count ?? -1)\n".utf8))
    let part = looking
    // Touching tiles at the orientation they agree on; on the table, each meld then as the likeliest valid one, as
    // between turns they all are.
    let turned = Recognizer.turned(found)
    if let ar, recording != nil { record(turned, ar) }
    let voted: [Detection]
    var melds: [[Detection]]?
    if let pose {
      world.add(turned, pose: pose, mask: ar?.mask)
      // Drawn and measured on the tabletop, not on whatever plane ARKit found; recorded as ARKit gave it.
      let leveled = world.level(pose)
      self.ar?.pose = leveled
      footprints = self.boxes.map(leveled.footprint)
      let placed = world.detections(from: pose).filter { $0.place.isRack == (part == .rack) }
      if part == .table { melds = Recognizer.valid(World.melds(placed)) }
      voted = melds?.flatMap(\.self) ?? placed.map(\.detection)
    } else {
      let seen = part == .rack ? onRack(turned) : Recognizer.valid(Recognizer.melds(turned)).flatMap(\.self)
      readings[part] = Array(((readings[part] ?? []) + [seen]).suffix(5))
      voted = vote(readings[part]!)
    }
    var next = scene
    if part == .table {
      next.table = melds ?? Recognizer.melds(voted)
    } else {
      next.rack = voted
    }

    if let play, let step, part == .table {
      let done = play.stepsDone(next.tableTiles, from: scene.tableTiles)
      if done == play.steps.count {
        // The play is on the table: take the table as it now reads, and the rack without what came from it.
        let used = Set(play.steps.compactMap { if case .rack(let i) = $0.from { i } else { nil } })
        scene = Scene(table: next.table, rack: scene.rack.indices.filter { !used.contains($0) }.map { scene.rack[$0] })
        self.step = nil
        opened = true
        await solve()
      } else if done > step {
        self.step = done
      }
      return
    }

    let same = next.tiles(part) == scene.tiles(part)
    if same {
      changedSince[part] = nil
      // Frames follow the tiles as the camera moves, but a reordering would break a play's indices.
      if next.reads(like: scene) { scene = next }
      let since = steadySince[part] ?? .now
      steadySince[part] = since
      if !locked.contains(part), Date.now.timeIntervalSince(since) >= 2,
        part == .table || !voted.isEmpty
      {
        locked.insert(part)
        if picked == part { picked = nil }
        await solve()
      }
    } else if locked.contains(part) {
      changedSince[part] = changedSince[part] ?? .now
    } else {
      scene = next
      steadySince[part] = .now
    }
  }

  /// Each part's last few frames' readings, newest last, without ARKit.
  private var readings = [Looking: [[Detection]]]()
  /// With ARKit, every tile read, by place on the table (`World`).
  @ObservationIgnored private var world = World()
  /// When each part's reading last changed while scanning.
  private var steadySince = [Looking: Date]()
  /// When a locked part's reading started disagreeing with it.
  private var changedSince = [Looking: Date]()
  /// The parts whose reading has held for two seconds; frames no longer change them, until `rescan`.
  var locked = Set<Looking>()
  private var lastSeen = Date.distantPast

  /// Both parts read and held, so the Solver draws them instead of showing the camera, which stops.
  var onBoard: Bool { locked.count == Looking.allCases.count }

  /// The table as read, with room around it for new melds.
  var tableBounds: CGRect? {
    let frames = scene.table.joined().map(\.frame)
    guard let first = frames.first else { return nil }
    let all = frames.reduce(first) { $0.union($1) }
    return all.insetBy(dx: -first.height * 1.5, dy: -first.height * 1.5)
  }

  /// Takes the chosen play as done: the board shows its melds where the steps put them, without a rescan.
  func finish() async {
    guard let play else { return }
    scene = play.finished(scene, within: tableBounds)
    step = nil
    opened = true
    await solve()
  }

  /// Whether a locked part has read differently for three seconds, as after someone's turn.
  func changed(_ part: Looking) -> Bool { changedSince[part].map { Date.now.timeIntervalSince($0) >= 3 } ?? false }

  /// Scans a part again, from scratch.
  func rescan(_ part: Looking) {
    locked.remove(part)
    readings[part] = nil
    world.forget(rack: part == .rack)
    changedSince[part] = nil
    steadySince[part] = .now
  }

  /// Readings by vote: each tile as many times as the median frame read it, since a frame often misses or misreads a
  /// tile or two of 14, and two frames rarely agree exactly.
  private func vote(_ readings: [[Detection]]) -> [Detection] {
    Set(readings.joined().map(\.tile)).sorted { $0.description < $1.description }.flatMap { tile in
      let counts = readings.map { $0.count { $0.tile == tile } }.sorted()
      let copies = counts[counts.count / 2]
      let seen = readings.last { $0.count { $0.tile == tile } >= copies } ?? []
      return seen.filter { $0.tile == tile }.prefix(copies)
    }
  }

  /// The rack's tiles. Tiles under a third of the tallest one's height are the table behind it: in rack captures those
  /// were 18–37 px tall, and the rack's 52 and up, but for one mostly hidden behind another. And the rack's two rows
  /// lie within a tile or so of its five tallest tiles, so anything farther above or below is something else.
  private func onRack(_ found: [Detection]) -> [Detection] {
    let tall = found.sorted { $0.frame.height > $1.frame.height }.prefix(5)
    let tallest = tall.first?.frame.height ?? 0
    let ys = tall.map(\.frame.midY).sorted()
    let middle = ys.isEmpty ? 0 : ys[ys.count / 2]
    return found.filter { $0.frame.height >= tallest / 3 && abs($0.frame.midY - middle) <= tallest * 1.5 }
  }

  /// What the last frame read that agrees with the settled table or rack, whichever is being looked at, so the
  /// Solver labels only those.
  var settled: [Detection] {
    var left = looking == .table ? scene.tableTiles.flatMap { $0 } : scene.rackTiles
    return (looking == .table ? detections : onRack(detections)).filter { detection in
      guard let i = left.firstIndex(of: detection.tile) else { return false }
      left.remove(at: i)
      return true
    }
  }

  /// Saves the last frame to Documents as `<time>.png`, its truth as `<time>.txt` (what it was looking at, then a meld
  /// a line), and everything else known about it as `<time>.json`, to become test fixtures. PNG, so the fixture is the
  /// same pixels the phone read.
  func capture(camera: [String: Any]) {
    guard let frame else { return }
    let base = URL.documentsDirectory.appending(path: Date.now.formatted(.iso8601))
    let destination = CGImageDestinationCreateWithURL(
      base.appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, frame, nil)
    CGImageDestinationFinalize(destination)
    let read = Recognizer.melds(detections).map { $0.map(\.tile.description).joined(separator: " ") }
    let tilt = tilt.map { " \(Int($0))°" } ?? ""
    try? (looking.rawValue + tilt + "\n" + (layout.melds ?? read).map { $0 + "\n" }.joined())
      .write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    var info: [String: Any] = [
      "looking": looking.rawValue, "layout": layout.rawValue, "notes": notes, "tilt": self.tilt ?? NSNull(),
      "gravity": gravity ?? [], "readMilliseconds": readTime / .milliseconds(1),
      "findMilliseconds": findTime / .milliseconds(1), "camera": camera, "read": read,
      "boxes": boxes.map { [$0.minX, $0.minY, $0.width, $0.height] },
      "detections": detections.map {
        ["tile": $0.tile.description, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]]
      },
    ]
    if let ar { info["ar"] = Self.info(ar, footprints: footprints) }
    if let recording { info["recording"] = recording.formatted(.iso8601) }
    try? JSONSerialization.data(withJSONObject: finite(info), options: [.prettyPrinted, .sortedKeys])
      .write(to: base.appendingPathExtension("json"))
  }

  /// An ARKit frame for a capture: matrices column by column, in metres; footprints a box at a time, each null where
  /// it never meets the table.
  nonisolated static func info(_ ar: Frame, footprints: [SIMD2<Float>?]) -> [String: Any]? {
    guard let pose = ar.pose else { return nil }
    func columns(_ m: simd_float4x4) -> [Float] { [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] } }
    let k = pose.intrinsics
    return [
      "transform": columns(pose.transform), "intrinsics": [k.columns.0, k.columns.1, k.columns.2].flatMap { [$0.x, $0.y, $0.z] },
      "resolution": [pose.resolution.width, pose.resolution.height], "tracking": ar.tracking,
      "plane": pose.plane.map(columns) ?? NSNull(),
      "planes": ar.planes.map {
        ["transform": columns($0.transform), "extent": [$0.extent.x, $0.extent.y], "classification": $0.classification]
      },
      "footprints": footprints.map { size -> Any in size.map { [$0.x, $0.y] } ?? NSNull() },
    ]
  }

  /// When the recording under way started. While it runs, every frame read with ARKit goes to a log, a line each,
  /// and every two seconds the frame is captured as well; it lands in Documents as `<start>.jsonl` once stopped.
  private(set) var recording: Date?
  @ObservationIgnored private var log: FileHandle?
  @ObservationIgnored private var lastKeyframe = Date.distantPast
  @ObservationIgnored private var recordingCamera = [String: Any]()
  /// Where the log is written until it's done, apart from what `Sync` sends.
  private static let recordings = URL.documentsDirectory.appending(path: "recording")

  func startRecording(camera: [String: Any]) {
    let start = Date.now
    try? FileManager.default.createDirectory(at: Self.recordings, withIntermediateDirectories: true)
    let url = Self.recordings.appending(path: start.formatted(.iso8601) + ".jsonl")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
    log = try? FileHandle(forWritingTo: url)
    recording = start
    recordingCamera = camera
    lastKeyframe = start
  }

  func stopRecording() {
    guard let recording else { return }
    try? log?.close()
    log = nil
    self.recording = nil
    let name = recording.formatted(.iso8601) + ".jsonl"
    try? FileManager.default.moveItem(at: Self.recordings.appending(path: name), to: URL.documentsDirectory.appending(path: name))
  }

  /// A line of the recording: the pose and plane, where a person covered the frame (a quarter size), and every read
  /// with its odds, as the world table got them. And the frame itself every two seconds.
  private func record(_ read: [Detection], _ ar: Frame) {
    guard var line = Self.info(ar, footprints: footprints) else { return }
    line.removeValue(forKey: "planes")
    line["time"] = Date.now.timeIntervalSince1970
    line["looking"] = looking.rawValue
    line["mask"] = ar.mask.map { mask in
      let small = mask.shrunk(by: 4)
      return ["width": small.width, "height": small.height, "bytes": Data(small.bytes).base64EncodedString()] as [String: Any]
    } ?? NSNull()
    line["detections"] = read.map {
      ["tile": $0.tile.description, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height],
       "turns": $0.turns, "rack": $0.rack ?? NSNull(),
       "odds": Dictionary(uniqueKeysWithValues: $0.odds.map { ($0.key.description, $0.value) })] as [String: Any]
    }
    if let data = try? JSONSerialization.data(withJSONObject: finite(line), options: .sortedKeys) {
      try? log?.write(contentsOf: data + Data("\n".utf8))
    }
    if Date.now.timeIntervalSince(lastKeyframe) >= 2 {
      lastKeyframe = .now
      capture(camera: recordingCamera)
    }
  }

  func solve() async {
    let table = scene.tableTiles, rack = scene.rackTiles, opened = opened
    plays = await Task.detached { RummikubKit.solve(table: table, rack: rack, opened: opened) }.value
    choice = max(0, plays.count - 1)
  }

  /// What to draw for the current step. The rack is never in the same frame as the table, so a tile from it can't be
  /// pointed at.
  var marks: [Mark] {
    guard let play, let step, play.steps.indices.contains(step) else { return [] }
    let group = play.group(at: step)
    if looking == .rack {
      guard case .rack = play.steps[step].from else { return [] }
      var left = detections
      return group.compactMap { i in
        left.firstIndex { $0.tile == play.steps[i].tile }.map { Mark.source(left.remove(at: $0).frame) }
      }
    }
    let bounds = frame.map { CGRect(x: 0, y: 0, width: $0.width, height: $0.height) }
    let following = scene.following(detections)
    let marks = group.flatMap { play.marks(in: following, step: $0, within: bounds) }
    guard case .rack = play.steps[step].from else { return marks }
    return marks.filter {
      switch $0 {
      case .source, .arrow: false
      default: true
      }
    }
  }
}

/// The value with NaN and infinities as null, which JSONSerialization throws on, crashing the app.
private func finite(_ value: Any) -> Any {
  switch value {
  case let dictionary as [String: Any]: dictionary.mapValues(finite)
  case let array as [Any]: array.map(finite)
  case let n as Double where !n.isFinite: NSNull()
  case let n as Float where !n.isFinite: NSNull()
  case let n as CGFloat where !n.isFinite: NSNull()
  default: value
  }
}

extension Scene {
  func reads(like other: Scene) -> Bool { tableTiles == other.tableTiles && rackTiles == other.rackTiles }

  /// A part's tiles in no order.
  func tiles(_ part: Game.Looking) -> [String] {
    (part == .table ? tableTiles.flatMap { $0 } : rackTiles).map(\.description).sorted()
  }
}
