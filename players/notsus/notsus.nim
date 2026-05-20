# This bot reads only sprite protocol metadata and object placements.
import
  std/[heapqueue, options, os, parseopt, random, strutils, times],
  supersnappy, whisky

when defined(notsusGui):
  import
    std/algorithm,
    pixie, silky, vmath, windy,
    scales

const
  ScreenWidth = 128
  ScreenHeight = 128
  SpriteSize = 12
  SpriteDrawOffX = 2
  SpriteDrawOffY = 8
  CollisionW = 1
  CollisionH = 1
  PlayerScreenX = ScreenWidth div 2
  PlayerScreenY = ScreenHeight div 2
  PlayerWorldOffX = SpriteDrawOffX + PlayerScreenX - SpriteSize div 2
  PlayerWorldOffY = SpriteDrawOffY + PlayerScreenY - SpriteSize div 2
  DefaultHost = "localhost"
  PlayerDefaultPort = 8080
  WebSocketPath = "/player"
  ButtonUp = 1'u8 shl 0
  ButtonDown = 1'u8 shl 1
  ButtonLeft = 1'u8 shl 2
  ButtonRight = 1'u8 shl 3
  ButtonA = 1'u8 shl 5
  PlayerObjectBase = 1000
  BodyObjectBase = 2000
  TaskObjectBase = 3000
  SpritePlayerTaskArrowObjectBase = 7000
  ProtocolVoteIconObjectBase = 9300
  ProtocolRoleIconObjectBase = 9500
  MaxPlayers = 16
  MaxDrainMessages = 512
  VoteListenTicks = 80
  VoteSkipPulseGap = 2
  VoteSkipSteps = MaxPlayers + 1
  TaskHoldTicks = 72
  TaskApproachRadius = 8
  ReportRange = 20
  KillRange = 20
  CoastLookaheadTicks = 8
  CoastArrivalPadding = 1
  ActorObjectPad = 1
  PathLookahead = 12
  PathRefreshTicks = 12
  PathGoalSlack = 4
  SteerDeadband = 2
  BrakeDeadband = 1
  StuckFrameThreshold = 10
  JiggleDuration = 14
  RoamGoalTicks = 72
  RoamGoalDistance = 120
  RoamGoalReach = 10
  PlayerColorNames = [
    "red",
    "orange",
    "yellow",
    "light blue",
    "pink",
    "lime",
    "blue",
    "pale blue",
    "gray",
    "white",
    "dark brown",
    "brown",
    "dark teal",
    "green",
    "dark navy",
    "black"
  ]

type
  SpriteKind = enum
    SpriteUnknown
    SpriteMap
    SpriteWalkability
    SpriteTask
    SpriteArrow
    SpritePlayer
    SpriteGhost
    SpriteBody
    SpriteImposter
    SpriteImposterCooldown
    SpriteGhostIcon
    SpriteScreen
    SpriteText

  SpriteInfo = ref object
    defined: bool
    width: int
    height: int
    label: string
    kind: SpriteKind
    colorIndex: int
    when defined(notsusGui):
      pixels: string

  ObjectState = object
    present: bool
    x: int
    y: int
    z: int
    layer: int
    spriteId: int

  BotRole = enum
    RoleCrewmate
    RoleImposter

  TaskState = enum
    TaskUnknown
    TaskMandatory
    TaskCompleted

  Target = object
    found: bool
    index: int
    x: int
    y: int

  PathNode = object
    priority: int
    index: int

  PathStep = object
    found: bool
    x: int
    y: int

  PlayerSight = object
    joinOrder: int
    x: int
    y: int
    colorIndex: int
    ghost: bool

  BodySight = object
    x: int
    y: int
    colorIndex: int

  ViewerApp = ref object
    when defined(notsusGui):
      window: Window
      silky: Silky
      contentScale: float32

  Bot = ref object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    mapWidth: int
    mapHeight: int
    walkabilityReceived: bool
    walkMask: seq[bool]
    rng: Rand
    role: BotRole
    isGhost: bool
    killReady: bool
    localized: bool
    interstitial: bool
    interstitialText: string
    cameraX: int
    cameraY: int
    playerX: int
    playerY: int
    previousPlayerX: int
    previousPlayerY: int
    velocityX: int
    velocityY: int
    haveMotionSample: bool
    stuckFrames: int
    jiggleTicks: int
    jiggleSide: int
    taskStates: seq[TaskState]
    taskTargets: seq[Target]
    taskVisible: seq[bool]
    taskArrow: seq[bool]
    taskHoldIndex: int
    taskHoldTicks: int
    goalX: int
    goalY: int
    goalName: string
    hasGoal: bool
    pathGoalX: int
    pathGoalY: int
    pathBuiltTick: int
    path: seq[PathStep]
    pathStep: PathStep
    pathParents: seq[int]
    pathCosts: seq[int]
    pathSeen: seq[int]
    pathClosed: seq[int]
    pathStamp: int
    hasRoamGoal: bool
    roamGoalX: int
    roamGoalY: int
    roamGoalTicks: int
    arrowMask: uint8
    visiblePlayers: seq[PlayerSight]
    visibleBodies: seq[BodySight]
    lastSeenTicks: seq[int]
    knownImposterColors: seq[bool]
    selfJoinOrder: int
    selfColorIndex: int
    lastBodySeenX: int
    lastBodySeenY: int
    pendingChat: string
    frameTick: int
    astarMicros: int
    voteStartTick: int
    voteStep: int
    voteDone: bool
    intent: string
    desiredMask: uint8
    controllerMask: uint8
    lastMask: uint8

proc fatal(message: string) {.noreturn.} =
  ## Exits with one fatal bot error.
  quit("notsus error: " & message, QuitFailure)

proc colorIndexFromName(name: string): int =
  ## Returns the player color index for a protocol color name.
  let lower = name.toLowerAscii()
  for i, value in PlayerColorNames:
    if value == lower:
      return i
  -1

proc actorColorName(label, prefix: string): string =
  ## Extracts a player color name from an actor sprite label.
  result = label.substr(prefix.len).toLowerAscii()
  if result.endsWith(" right"):
    result.setLen(result.len - " right".len)
  elif result.endsWith(" left"):
    result.setLen(result.len - " left".len)
  result = result.strip()

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes for Nim heapqueue.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc classifySprite(label: string): tuple[kind: SpriteKind, colorIndex: int] =
  ## Classifies a sprite definition by its stable label.
  let lower = label.toLowerAscii()
  result = (kind: SpriteUnknown, colorIndex: -1)
  if lower == "map":
    result.kind = SpriteMap
  elif lower == "walkability map":
    result.kind = SpriteWalkability
  elif lower == "task bubble":
    result.kind = SpriteTask
  elif lower == "task arrow":
    result.kind = SpriteArrow
  elif lower == "imposter icon":
    result.kind = SpriteImposter
  elif lower == "imposter icon cooldown":
    result.kind = SpriteImposterCooldown
  elif lower == "ghost icon":
    result.kind = SpriteGhostIcon
  elif lower == "interstitial background" or
      lower == "vote chat background":
    result.kind = SpriteScreen
  elif lower == "vote cursor" or
      lower == "vote skip cursor" or
      lower == "vote timer" or
      lower == "shadow" or
      lower.startsWith("vote self marker ") or
      lower.startsWith("vote dot ") or
      lower.startsWith("task counter ") or
      lower.startsWith("progress bar "):
    result.kind = SpriteUnknown
  elif lower.startsWith("body "):
    result.kind = SpriteBody
    result.colorIndex = colorIndexFromName(lower.substr("body ".len))
  elif lower.startsWith("player "):
    result.kind = SpritePlayer
    result.colorIndex = colorIndexFromName(actorColorName(lower, "player "))
  elif lower.startsWith("ghost "):
    result.kind = SpriteGhost
    result.colorIndex = colorIndexFromName(actorColorName(lower, "ghost "))
  elif lower.len > 0:
    result.kind = SpriteText

proc ensureSprite(bot: var Bot, spriteId: int) =
  ## Ensures the sprite table can hold a sprite id.
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  ## Ensures the object table can hold an object id.
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc ensureTask(bot: var Bot, taskIndex: int) =
  ## Ensures task-indexed tables can hold one task.
  if taskIndex < 0:
    return
  if taskIndex >= bot.taskStates.len:
    let length = taskIndex + 1
    bot.taskStates.setLen(length)
    bot.taskTargets.setLen(length)
    bot.taskVisible.setLen(length)
    bot.taskArrow.setLen(length)

proc spriteKind(info: SpriteInfo): SpriteKind =
  ## Returns the safe kind for optional sprite metadata.
  if info.isNil:
    return SpriteUnknown
  info.kind

proc spriteLabel(info: SpriteInfo): string =
  ## Returns the safe label for optional sprite metadata.
  if info.isNil:
    return ""
  info.label

proc spriteWidth(info: SpriteInfo): int =
  ## Returns the safe width for optional sprite metadata.
  if info.isNil:
    return 0
  info.width

proc spriteHeight(info: SpriteInfo): int =
  ## Returns the safe height for optional sprite metadata.
  if info.isNil:
    return 0
  info.height

proc spriteColorIndex(info: SpriteInfo): int =
  ## Returns the safe player color index for optional sprite metadata.
  if info.isNil:
    return -1
  info.colorIndex

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  ## Returns sprite metadata or nil for unknown sprites.
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]

proc objectSprite(bot: Bot, objectState: ObjectState): SpriteInfo =
  ## Returns sprite metadata for an object.
  bot.spriteInfo(objectState.spriteId)

proc readU16(blob: string, offset: int): int =
  ## Reads one little endian unsigned 16 bit value.
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  ## Reads one little endian signed 16 bit value.
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  ## Reads one little endian unsigned 32 bit value.
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc decodeSpritePixels(
  width,
  height: int,
  compressed: string,
  rawPixels: var string
): bool =
  ## Decodes one compressed RGBA sprite payload.
  try:
    rawPixels = supersnappy.uncompress(compressed)
  except CatchableError:
    return false
  if width <= 0 or height <= 0 or rawPixels.len != width * height * 4:
    return false
  true

proc applyWalkabilityPixels(
  bot: var Bot,
  width,
  height: int,
  rawPixels: string
): bool =
  ## Applies the single bitmap payload used for navigation.
  if width <= 0 or height <= 0 or rawPixels.len != width * height * 4:
    return false
  bot.mapWidth = width
  bot.mapHeight = height
  bot.walkMask = newSeq[bool](width * height)
  var walkableCount = 0
  for i in 0 ..< width * height:
    bot.walkMask[i] = rawPixels[i * 4 + 3].uint8 > 0
    if bot.walkMask[i]:
      inc walkableCount
  if walkableCount == 0:
    return false
  bot.walkabilityReceived = true
  bot.path.setLen(0)
  bot.pathStamp = 0
  true

proc applySpritePacket(bot: var Bot, packet: string, gui = false): bool =
  ## Applies sprite protocol messages and decodes art only for GUI.
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len:
        return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len:
        return false
      let compressedStart = offset
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len:
        return false
      let label =
        if labelLen > 0:
          packet.substr(offset, offset + labelLen - 1)
        else:
          ""
      offset += labelLen
      let classified = classifySprite(label)
      bot.ensureSprite(spriteId)
      let info = SpriteInfo(
        defined: true,
        width: width,
        height: height,
        label: label,
        kind: classified.kind,
        colorIndex: classified.colorIndex
      )
      var shouldDecode = classified.kind == SpriteWalkability
      when defined(notsusGui):
        shouldDecode = shouldDecode or gui
      if shouldDecode:
        let compressed =
          if compressedLen > 0:
            packet.substr(compressedStart, compressedStart + compressedLen - 1)
          else:
            ""
        var rawPixels = ""
        if not decodeSpritePixels(width, height, compressed, rawPixels):
          return false
        if classified.kind == SpriteWalkability:
          if not bot.applyWalkabilityPixels(width, height, rawPixels):
            return false
        when defined(notsusGui):
          if gui:
            info.pixels = rawPixels
      bot.sprites[spriteId] = info
    of 0x02:
      if offset + 11 > packet.len:
        return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        z = packet.readI16(offset + 6)
        layer = int(packet[offset + 8].uint8)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(
        present: true,
        x: x,
        y: y,
        z: z,
        layer: layer,
        spriteId: spriteId
      )
    of 0x03:
      if offset + 2 > packet.len:
        return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
    of 0x05:
      if offset + 5 > packet.len:
        return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len:
        return false
      offset += 3
    else:
      return false
  true

proc blobFromBytes(bytes: openArray[uint8]): string =
  ## Builds a binary websocket payload from protocol bytes.
  result = newString(bytes.len)
  for i, value in bytes:
    result[i] = char(value)

proc addU16(packet: var seq[uint8], value: int) =
  ## Appends one little endian unsigned 16 bit value.
  let v = uint16(value)
  packet.add(uint8(v and 0xff'u16))
  packet.add(uint8(v shr 8))

proc playerInputBlob(mask: uint8): string =
  ## Builds a sprite protocol player input packet.
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc chatBlob(text: string): string =
  ## Builds a sprite protocol text input packet.
  var bytes: seq[uint8] = @[0x81'u8]
  bytes.addU16(text.len)
  for ch in text:
    bytes.add(uint8(ord(ch)))
  blobFromBytes(bytes)

proc queryEscape(value: string): string =
  ## Escapes a query string component.
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc addQueryParam(
  url: var string,
  first: var bool,
  key,
  value: string
) =
  ## Adds one escaped query parameter to a websocket URL.
  if value.len == 0:
    return
  if first:
    url.add('?')
    first = false
  else:
    url.add('&')
  url.add(key.queryEscape())
  url.add('=')
  url.add(value.queryEscape())

proc playerUrl(
  host: string,
  port: int,
  name,
  slot,
  token,
  explicitUrl: string
): string =
  ## Builds the sprite protocol player endpoint URL.
  if explicitUrl.len > 0:
    return explicitUrl
  result = "ws://" & host & ":" & $port & WebSocketPath
  var first = true
  result.addQueryParam(first, "name", name)
  result.addQueryParam(first, "slot", slot)
  result.addQueryParam(first, "token", token)

proc objectActorWorldX(bot: Bot, objectState: ObjectState): int =
  ## Converts an actor object X position into map coordinates.
  objectState.x + bot.cameraX + SpriteDrawOffX + ActorObjectPad +
    CollisionW div 2

proc objectActorWorldY(bot: Bot, objectState: ObjectState): int =
  ## Converts an actor object Y position into map coordinates.
  objectState.y + bot.cameraY + SpriteDrawOffY + ActorObjectPad +
    CollisionH div 2

proc objectTaskTarget(bot: Bot, objectState: ObjectState): tuple[x, y: int] =
  ## Converts a task icon object into an approximate action point.
  let sprite = bot.objectSprite(objectState)
  (
    x: objectState.x + bot.cameraX + sprite.spriteWidth() div 2,
    y: objectState.y + bot.cameraY + sprite.spriteHeight() + 8
  )

proc mapIndex(bot: Bot, x, y: int): int =
  ## Returns the walkability map index.
  y * bot.mapWidth + x

proc passable(bot: Bot, x, y: int): bool =
  ## Returns true when a collision-sized body can occupy a pixel.
  if bot.walkMask.len == 0 or bot.mapWidth <= 0 or bot.mapHeight <= 0:
    return false
  if x < 0 or y < 0 or x + CollisionW > bot.mapWidth or
      y + CollisionH > bot.mapHeight:
    return false
  for dy in 0 ..< CollisionH:
    for dx in 0 ..< CollisionW:
      if not bot.walkMask[bot.mapIndex(x + dx, y + dy)]:
        return false
  true

proc heuristic(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance.
  abs(ax - bx) + abs(ay - by)

proc nearestPassableTarget(
  bot: Bot,
  targetX,
  targetY: int
): tuple[found: bool, x: int, y: int] =
  ## Finds a nearby walkable pixel for an approximate target.
  if bot.passable(targetX, targetY):
    return (found: true, x: targetX, y: targetY)
  var
    bestDistance = high(int)
    bestX = 0
    bestY = 0
  for radius in [4, 8, 16, 32, 64]:
    for y in max(0, targetY - radius) .. min(bot.mapHeight - 1, targetY + radius):
      for x in max(0, targetX - radius) .. min(bot.mapWidth - 1, targetX + radius):
        if not bot.passable(x, y):
          continue
        let distance = heuristic(targetX, targetY, x, y)
        if distance < bestDistance:
          bestDistance = distance
          bestX = x
          bestY = y
    if bestDistance != high(int):
      return (found: true, x: bestX, y: bestY)

proc ensurePathBuffers(bot: var Bot, area: int) =
  ## Ensures reusable A* buffers match the current walkability map.
  if bot.pathParents.len != area:
    bot.pathParents.setLen(area)
    bot.pathCosts.setLen(area)
    bot.pathSeen.setLen(area)
    bot.pathClosed.setLen(area)
    bot.pathStamp = 0
  inc bot.pathStamp
  if bot.pathStamp == high(int):
    for i in 0 ..< area:
      bot.pathSeen[i] = 0
      bot.pathClosed[i] = 0
    bot.pathStamp = 1

proc reconstructPath(
  bot: Bot,
  parents: openArray[int],
  startIndex,
  goalIndex: int
): seq[PathStep] =
  ## Reconstructs a complete path from a parent table.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add PathStep(
      found: true,
      x: stepIndex mod bot.mapWidth,
      y: stepIndex div bot.mapWidth
    )
    stepIndex = parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc findPath(bot: var Bot, goalX, goalY: int): seq[PathStep] =
  ## Finds a complete A* pixel path toward a goal.
  if bot.walkMask.len == 0 or bot.mapWidth <= 0 or bot.mapHeight <= 0:
    return
  let target = bot.nearestPassableTarget(goalX, goalY)
  if not target.found:
    return
  let start = bot.nearestPassableTarget(bot.playerX, bot.playerY)
  if not start.found:
    return
  let
    startX = start.x
    startY = start.y
    area = bot.mapWidth * bot.mapHeight
    startIndex = bot.mapIndex(startX, startY)
    goalIndex = bot.mapIndex(target.x, target.y)
  bot.ensurePathBuffers(area)
  var
    stamp = bot.pathStamp
    openSet: HeapQueue[PathNode]
  bot.pathParents[startIndex] = -1
  bot.pathCosts[startIndex] = 0
  bot.pathSeen[startIndex] = stamp
  openSet.push PathNode(
    priority: heuristic(startX, startY, target.x, target.y),
    index: startIndex
  )
  while openSet.len > 0:
    let current = openSet.pop()
    if bot.pathClosed[current.index] == stamp:
      continue
    if current.index == goalIndex:
      return bot.reconstructPath(bot.pathParents, startIndex, goalIndex)
    bot.pathClosed[current.index] = stamp
    let
      x = current.index mod bot.mapWidth
      y = current.index div bot.mapWidth
    for delta in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let
        nx = x + delta[0]
        ny = y + delta[1]
      if not bot.passable(nx, ny):
        continue
      let nextIndex = bot.mapIndex(nx, ny)
      if bot.pathClosed[nextIndex] == stamp:
        continue
      let newCost = bot.pathCosts[current.index] + 1
      if bot.pathSeen[nextIndex] == stamp and
          newCost >= bot.pathCosts[nextIndex]:
        continue
      bot.pathSeen[nextIndex] = stamp
      bot.pathCosts[nextIndex] = newCost
      bot.pathParents[nextIndex] = current.index
      openSet.push PathNode(
        priority: newCost + heuristic(nx, ny, target.x, target.y),
        index: nextIndex
      )

proc segmentPassable(bot: Bot, ax, ay, bx, by: int): bool =
  ## Returns true when a straight segment stays on walkable pixels.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return bot.passable(ax, ay)
  for i in 0 .. steps:
    let
      x = ax + dx * i div steps
      y = ay + dy * i div steps
    if not bot.passable(x, y):
      return false
  true

proc choosePathStep(bot: Bot): PathStep =
  ## Returns a visible short-lookahead waypoint from the current path.
  if bot.path.len == 0:
    return
  var
    bestIndex = 0
    bestDistance = high(int)
  for i, step in bot.path:
    let distance = heuristic(bot.playerX, bot.playerY, step.x, step.y)
    if distance < bestDistance:
      bestDistance = distance
      bestIndex = i
  result = bot.path[min(bot.path.high, bestIndex + 1)]
  let farIndex = min(bot.path.high, bestIndex + PathLookahead)
  for i in bestIndex + 1 .. farIndex:
    let step = bot.path[i]
    if bot.segmentPassable(bot.playerX, bot.playerY, step.x, step.y):
      result = step
    else:
      break

proc pathNeedsRefresh(bot: Bot, x, y: int): bool =
  ## Returns true when the cached path is stale.
  if bot.path.len == 0:
    return true
  if abs(bot.pathGoalX - x) + abs(bot.pathGoalY - y) > PathGoalSlack:
    return true
  bot.frameTick - bot.pathBuiltTick >= PathRefreshTicks

proc requireWalkability(bot: Bot) =
  ## Fails if the server did not provide the required navigation sprite.
  if bot.walkabilityReceived and bot.walkMask.len > 0:
    return
  fatal(
    "server did not send required sprite labeled \"walkability map\"; " &
    "A* navigation cannot run"
  )

proc updateMotion(bot: var Bot) =
  ## Updates local velocity and stuck detection from sprite positions.
  if not bot.localized:
    bot.haveMotionSample = false
    bot.velocityX = 0
    bot.velocityY = 0
    return
  if bot.haveMotionSample:
    bot.velocityX = bot.playerX - bot.previousPlayerX
    bot.velocityY = bot.playerY - bot.previousPlayerY
    let moving = (bot.lastMask and (
      ButtonUp or ButtonDown or ButtonLeft or ButtonRight
    )) != 0
    if moving and abs(bot.velocityX) + abs(bot.velocityY) == 0:
      inc bot.stuckFrames
    else:
      bot.stuckFrames = 0
    if bot.stuckFrames >= StuckFrameThreshold:
      bot.stuckFrames = 0
      bot.jiggleTicks = JiggleDuration
      bot.jiggleSide = 1 - bot.jiggleSide
  else:
    bot.velocityX = 0
    bot.velocityY = 0
    bot.stuckFrames = 0
  bot.haveMotionSample = true
  bot.previousPlayerX = bot.playerX
  bot.previousPlayerY = bot.playerY

proc resetRoundKnowledge(bot: var Bot) =
  ## Resets state that belongs to one round.
  bot.role = RoleCrewmate
  bot.isGhost = false
  bot.killReady = false
  for state in bot.taskStates.mitems:
    state = TaskUnknown
  bot.taskHoldIndex = -1
  bot.taskHoldTicks = 0
  bot.visiblePlayers.setLen(0)
  bot.visibleBodies.setLen(0)
  for known in bot.knownImposterColors.mitems:
    known = false
  bot.pendingChat = ""
  bot.voteStartTick = -1
  bot.voteStep = 0
  bot.voteDone = false

proc sameBody(ax, ay, bx, by: int): bool =
  ## Returns true when two body sightings are probably the same body.
  if bx == low(int) or by == low(int):
    return false
  abs(ax - bx) + abs(ay - by) <= 6

proc playerColorName(colorIndex: int): string =
  ## Returns the visible player color name.
  if colorIndex >= 0 and colorIndex < PlayerColorNames.len:
    return PlayerColorNames[colorIndex]
  "unknown"

proc rememberImposterColor(bot: var Bot, colorIndex: int) =
  ## Records one known imposter color.
  if colorIndex >= 0 and colorIndex < bot.knownImposterColors.len:
    bot.knownImposterColors[colorIndex] = true

proc clearImposterColors(bot: var Bot) =
  ## Clears remembered imposter colors for a new role reveal.
  for known in bot.knownImposterColors.mitems:
    known = false

proc knowsImposterColor(bot: Bot, colorIndex: int): bool =
  ## Returns true when a color is known to be an imposter.
  colorIndex >= 0 and colorIndex < bot.knownImposterColors.len and
    bot.knownImposterColors[colorIndex]

proc knownImposterSummary(bot: Bot): string {.used.} =
  ## Returns a readable summary of known imposter colors.
  var names: seq[string] = @[]
  for i, known in bot.knownImposterColors:
    if known:
      names.add(playerColorName(i))
  if names.len == 0:
    return "none"
  names.join(", ")

proc suspectedColor(
  bot: Bot
): tuple[found: bool, colorIndex: int, tick: int] =
  ## Returns the most recently seen non-self crewmate color.
  var bestTick = -1
  for i, tick in bot.lastSeenTicks:
    if i == bot.selfColorIndex:
      continue
    if tick > bestTick:
      bestTick = tick
      result = (found: true, colorIndex: i, tick: tick)

proc bodyRoomMessage(bot: Bot): string =
  ## Builds the voting chat message for a body sighting.
  result = "body"
  let suspect = bot.suspectedColor()
  if suspect.found:
    result.add(" sus ")
    result.add(playerColorName(suspect.colorIndex))

proc queueBodySeen(bot: var Bot, x, y: int) =
  ## Stores one body report message until voting begins.
  if sameBody(x, y, bot.lastBodySeenX, bot.lastBodySeenY):
    return
  bot.lastBodySeenX = x
  bot.lastBodySeenY = y
  bot.pendingChat = bot.bodyRoomMessage()

proc arrowMaskFromScreenPoint(x, y: int): uint8 =
  ## Converts an edge arrow screen position into a movement mask.
  let
    dx = x - PlayerScreenX
    dy = y - PlayerScreenY
  if abs(dx) >= abs(dy):
    if dx < 0:
      return ButtonLeft
    return ButtonRight
  if dy < 0:
    return ButtonUp
  ButtonDown

proc learnRoleReveal(bot: var Bot) =
  ## Learns role and teammate colors from the role reveal screen.
  let text = bot.interstitialText.strip()
  if text == "CREWMATE":
    bot.role = RoleCrewmate
    bot.clearImposterColors()
    return
  if text != "IMPS":
    return
  bot.role = RoleImposter
  bot.clearImposterColors()
  for objectId, objectState in bot.objects:
    if not objectState.present:
      continue
    if objectId < ProtocolRoleIconObjectBase or
        objectId >= ProtocolRoleIconObjectBase + MaxPlayers:
      continue
    let info = bot.objectSprite(objectState)
    if info.spriteKind() == SpritePlayer:
      bot.rememberImposterColor(info.spriteColorIndex())

proc analyzeObjects(bot: var Bot) =
  ## Rebuilds semantic state from object positions and sprite labels.
  bot.localized = false
  bot.interstitial = false
  bot.interstitialText = ""
  bot.killReady = false
  bot.arrowMask = 0
  bot.visiblePlayers.setLen(0)
  bot.visibleBodies.setLen(0)
  for i in 0 ..< bot.taskVisible.len:
    bot.taskVisible[i] = false
    bot.taskArrow[i] = false
    bot.taskTargets[i].found = false

  var
    sawGhostIcon = false
    sawImposterIcon = false
    sawCooldownIcon = false
  for objectState in bot.objects:
    if not objectState.present:
      continue
    let info = bot.objectSprite(objectState)
    case info.spriteKind()
    of SpriteMap:
      bot.localized = true
      bot.cameraX = -objectState.x
      bot.cameraY = -objectState.y
      bot.playerX = bot.cameraX + PlayerWorldOffX
      bot.playerY = bot.cameraY + PlayerWorldOffY
    of SpriteScreen:
      bot.interstitial = true
    of SpriteText:
      let label = info.spriteLabel()
      if label.len > 0:
        if bot.interstitialText.len > 0:
          bot.interstitialText.add(" ")
        bot.interstitialText.add(label)
    of SpriteGhostIcon:
      sawGhostIcon = true
    of SpriteImposter:
      sawImposterIcon = true
    of SpriteImposterCooldown:
      sawCooldownIcon = true
    else:
      discard

  if bot.interstitialText.contains("CREW WINS") or
      bot.interstitialText.contains("IMPS WIN") or
      bot.interstitialText.contains("DRAW"):
    bot.resetRoundKnowledge()
  if bot.interstitial:
    bot.learnRoleReveal()

  if bot.localized and not bot.interstitial:
    bot.role =
      if sawImposterIcon or sawCooldownIcon:
        RoleImposter
      else:
        RoleCrewmate
    bot.killReady = sawImposterIcon
    bot.isGhost = sawGhostIcon

  if not bot.localized:
    bot.updateMotion()
    return

  for objectId, objectState in bot.objects:
    if not objectState.present:
      continue
    let info = bot.objectSprite(objectState)
    let kind = info.spriteKind()
    if kind == SpriteTask:
      let taskIndex = objectId - TaskObjectBase
      bot.ensureTask(taskIndex)
      if taskIndex >= 0 and taskIndex < bot.taskTargets.len:
        let target = bot.objectTaskTarget(objectState)
        bot.taskVisible[taskIndex] = true
        bot.taskTargets[taskIndex] = Target(
          found: true,
          index: taskIndex,
          x: target.x,
          y: target.y
        )
    elif kind == SpriteArrow:
      let taskIndex = objectId - SpritePlayerTaskArrowObjectBase
      bot.ensureTask(taskIndex)
      if taskIndex >= 0 and taskIndex < bot.taskArrow.len:
        bot.taskArrow[taskIndex] = true
      if bot.arrowMask == 0:
        bot.arrowMask = arrowMaskFromScreenPoint(objectState.x, objectState.y)
    elif kind in {SpritePlayer, SpriteGhost} and
        objectId >= PlayerObjectBase and
        objectId < PlayerObjectBase + MaxPlayers:
      let sight = PlayerSight(
        joinOrder: objectId - PlayerObjectBase,
        x: bot.objectActorWorldX(objectState),
        y: bot.objectActorWorldY(objectState),
        colorIndex: info.spriteColorIndex(),
        ghost: kind == SpriteGhost
      )
      if abs(sight.x - bot.playerX) <= 1 and
          abs(sight.y - bot.playerY) <= 1:
        bot.selfJoinOrder = sight.joinOrder
        bot.selfColorIndex = sight.colorIndex
      bot.visiblePlayers.add(sight)
    elif kind == SpriteBody and objectId >= BodyObjectBase and
        objectId < BodyObjectBase + MaxPlayers:
      bot.visibleBodies.add BodySight(
        x: bot.objectActorWorldX(objectState),
        y: bot.objectActorWorldY(objectState),
        colorIndex: info.spriteColorIndex()
      )

  for player in bot.visiblePlayers:
    if player.joinOrder == bot.selfJoinOrder:
      continue
    if abs(player.x - bot.playerX) <= 1 and
        abs(player.y - bot.playerY) <= 1:
      continue
    if player.colorIndex >= 0 and player.colorIndex < bot.lastSeenTicks.len:
      bot.lastSeenTicks[player.colorIndex] = bot.frameTick
  if bot.role == RoleImposter:
    bot.rememberImposterColor(bot.selfColorIndex)
  if bot.role == RoleCrewmate and not bot.isGhost:
    for body in bot.visibleBodies:
      bot.queueBodySeen(body.x, body.y)
      break
  for i in 0 ..< bot.taskStates.len:
    if bot.taskVisible[i] or bot.taskArrow[i]:
      if bot.taskStates[i] != TaskCompleted:
        bot.taskStates[i] = TaskMandatory
  bot.updateMotion()

proc visibleVoteCount(bot: Bot): int =
  ## Counts voting candidate actor objects.
  for objectId, objectState in bot.objects:
    if not objectState.present:
      continue
    if objectId >= ProtocolVoteIconObjectBase and
        objectId < ProtocolVoteIconObjectBase + MaxPlayers:
      let info = bot.objectSprite(objectState)
      if info.spriteKind() in {SpritePlayer, SpriteBody}:
        result = max(result, objectId - ProtocolVoteIconObjectBase + 1)

proc inRange(bot: Bot, targetX, targetY, range: int): bool =
  ## Returns true when the bot is within a square-distance range.
  let
    dx = bot.playerX - targetX
    dy = bot.playerY - targetY
  dx * dx + dy * dy <= range * range

proc coastDistance(velocity: int): int =
  ## Returns how far current velocity will carry without input.
  var speed = abs(velocity)
  for _ in 0 ..< CoastLookaheadTicks:
    if speed <= 0:
      break
    result += speed
    speed = (speed * 144) div 256

proc shouldCoast(delta, velocity: int): bool =
  ## Returns true when existing velocity should reach the target.
  if delta > 0 and velocity > 0:
    return delta <= coastDistance(velocity) + CoastArrivalPadding
  if delta < 0 and velocity < 0:
    return -delta <= coastDistance(velocity) + CoastArrivalPadding

proc axisMask(delta, velocity: int, negativeMask, positiveMask: uint8): uint8 =
  ## Returns steering for one axis with coasting and braking.
  if delta > SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity > 1 and delta <= abs(velocity) + BrakeDeadband:
      return negativeMask
    return positiveMask
  if delta < -SteerDeadband:
    if shouldCoast(delta, velocity):
      return 0
    if velocity < -1 and -delta <= abs(velocity) + BrakeDeadband:
      return positiveMask
    return negativeMask
  if velocity > 0:
    return negativeMask
  if velocity < 0:
    return positiveMask
  0

proc applyJiggle(bot: var Bot, mask: uint8): uint8 =
  ## Adds a short perpendicular correction while keeping intent held.
  result = mask
  if bot.jiggleTicks <= 0:
    return
  dec bot.jiggleTicks
  if (mask and (ButtonUp or ButtonDown)) != 0:
    if bot.jiggleSide == 0:
      result = result or ButtonLeft
    else:
      result = result or ButtonRight
  elif (mask and (ButtonLeft or ButtonRight)) != 0:
    if bot.jiggleSide == 0:
      result = result or ButtonUp
    else:
      result = result or ButtonDown

proc steerTowardPoint(bot: var Bot, x, y: int): uint8 =
  ## Steers directly toward one world point.
  let
    dx = x - bot.playerX
    dy = y - bot.playerY
  result = result or axisMask(dx, bot.velocityX, ButtonLeft, ButtonRight)
  result = result or axisMask(dy, bot.velocityY, ButtonUp, ButtonDown)
  result = bot.applyJiggle(result)

proc setRoamGoal(bot: var Bot, x, y: int): bool =
  ## Sets a roaming goal near one requested point.
  let target = bot.nearestPassableTarget(x, y)
  if not target.found:
    return false
  bot.hasRoamGoal = true
  bot.roamGoalX = target.x
  bot.roamGoalY = target.y
  bot.roamGoalTicks = RoamGoalTicks
  true

proc chooseArrowRoamGoal(bot: var Bot): bool =
  ## Chooses a passable exploration goal in the task-arrow direction.
  if bot.arrowMask == 0:
    return false
  var
    dx = 0
    dy = 0
  if (bot.arrowMask and ButtonLeft) != 0:
    dx = -1
  elif (bot.arrowMask and ButtonRight) != 0:
    dx = 1
  if (bot.arrowMask and ButtonUp) != 0:
    dy = -1
  elif (bot.arrowMask and ButtonDown) != 0:
    dy = 1
  let
    goalX = clamp(
      bot.playerX + dx * RoamGoalDistance,
      0,
      bot.mapWidth - 1
    )
    goalY = clamp(
      bot.playerY + dy * RoamGoalDistance,
      0,
      bot.mapHeight - 1
    )
  bot.setRoamGoal(goalX, goalY)

proc chooseRandomRoamGoal(bot: var Bot): bool =
  ## Chooses a random passable exploration goal.
  for _ in 0 ..< 64:
    let
      x = bot.rng.rand(max(0, bot.mapWidth - 1))
      y = bot.rng.rand(max(0, bot.mapHeight - 1))
    if bot.setRoamGoal(x, y):
      return true

proc ensureRoamGoal(bot: var Bot): bool =
  ## Ensures roaming has a current A* target.
  bot.requireWalkability()
  if bot.hasRoamGoal:
    if heuristic(
      bot.playerX,
      bot.playerY,
      bot.roamGoalX,
      bot.roamGoalY
    ) <= RoamGoalReach:
      bot.hasRoamGoal = false
    elif bot.roamGoalTicks > 0:
      dec bot.roamGoalTicks
      return true
    else:
      bot.hasRoamGoal = false
  if bot.chooseArrowRoamGoal():
    return true
  bot.chooseRandomRoamGoal()

proc navigateToPoint(bot: var Bot, x, y: int, name: string): uint8 =
  ## Navigates toward one world point using A*.
  bot.requireWalkability()
  bot.hasGoal = true
  bot.goalX = x
  bot.goalY = y
  bot.goalName = name
  bot.intent = "A* to " & name
  if bot.pathNeedsRefresh(x, y):
    let astarStart = epochTime()
    bot.path = bot.findPath(x, y)
    bot.astarMicros = int((epochTime() - astarStart) * 1_000_000.0)
    bot.pathGoalX = x
    bot.pathGoalY = y
    bot.pathBuiltTick = bot.frameTick
  bot.pathStep = bot.choosePathStep()
  if bot.pathStep.found:
    return bot.steerTowardPoint(bot.pathStep.x, bot.pathStep.y)
  bot.intent = "no A* path to " & name
  0

proc nearestTaskTarget(bot: Bot): Target =
  ## Returns the closest visible or arrowed task target.
  var bestDistance = high(int)
  for i in 0 ..< bot.taskTargets.len:
    if bot.taskStates[i] == TaskCompleted:
      continue
    if not bot.taskTargets[i].found:
      continue
    let target = bot.taskTargets[i]
    let distance = heuristic(bot.playerX, bot.playerY, target.x, target.y)
    if distance < bestDistance:
      bestDistance = distance
      result = target

proc nearestBody(bot: Bot): tuple[found: bool, x: int, y: int] =
  ## Returns the nearest visible dead body.
  var bestDistance = high(int)
  for body in bot.visibleBodies:
    let distance = heuristic(bot.playerX, bot.playerY, body.x, body.y)
    if distance < bestDistance:
      bestDistance = distance
      result = (found: true, x: body.x, y: body.y)

proc nearestVisibleCrewmate(
  bot: Bot
): tuple[found: bool, sight: PlayerSight, count: int] =
  ## Returns the nearest visible non-self alive crewmate.
  var bestDistance = high(int)
  for player in bot.visiblePlayers:
    if player.ghost:
      continue
    if bot.knowsImposterColor(player.colorIndex):
      continue
    if player.joinOrder == bot.selfJoinOrder:
      continue
    if abs(player.x - bot.playerX) <= 1 and
        abs(player.y - bot.playerY) <= 1:
      continue
    inc result.count
    let distance = heuristic(bot.playerX, bot.playerY, player.x, player.y)
    if distance < bestDistance:
      bestDistance = distance
      result.found = true
      result.sight = player

proc freshA(bot: Bot): uint8 =
  ## Returns an action press only after releasing any previous action.
  if (bot.lastMask and ButtonA) != 0:
    return 0
  ButtonA

proc holdTaskAction(bot: var Bot): uint8 =
  ## Holds only the action button while completing a task.
  bot.intent = "doing task"
  if bot.taskHoldTicks > 0:
    dec bot.taskHoldTicks
  if bot.taskHoldTicks == 0:
    if bot.taskHoldIndex >= 0 and bot.taskHoldIndex < bot.taskStates.len:
      bot.taskStates[bot.taskHoldIndex] = TaskCompleted
    bot.taskHoldIndex = -1
  ButtonA

proc randomRoam(bot: var Bot): uint8 =
  ## Returns an A* exploration movement mask.
  for _ in 0 ..< 4:
    if not bot.ensureRoamGoal():
      bot.intent = "no roam goal"
      return 0
    let mask = bot.navigateToPoint(
      bot.roamGoalX,
      bot.roamGoalY,
      "roam"
    )
    if bot.pathStep.found:
      bot.intent =
        if bot.arrowMask != 0:
          "A* along task arrow"
        else:
          "A* roam"
      return mask
    bot.hasRoamGoal = false
  bot.intent = "no A* roam path"
  0

proc decideCrewmateMask(bot: var Bot): uint8 =
  ## Chooses crewmate movement, reporting, and task actions.
  if not bot.localized:
    bot.intent = "not localized"
    return 0
  if bot.taskHoldTicks > 0:
    return bot.holdTaskAction()
  if not bot.isGhost:
    let body = bot.nearestBody()
    if body.found:
      if bot.inRange(body.x, body.y, ReportRange):
        bot.intent = "report body"
        return bot.freshA()
      return bot.navigateToPoint(body.x, body.y, "body")
  let task = bot.nearestTaskTarget()
  if task.found:
    if heuristic(bot.playerX, bot.playerY, task.x, task.y) <=
        TaskApproachRadius:
      bot.taskHoldIndex = task.index
      bot.taskHoldTicks = TaskHoldTicks
      return bot.holdTaskAction()
    return bot.navigateToPoint(task.x, task.y, "task " & $task.index)
  bot.randomRoam()

proc decideImposterMask(bot: var Bot): uint8 =
  ## Chooses imposter movement and kill behavior.
  bot.taskHoldTicks = 0
  bot.taskHoldIndex = -1
  let crewmate = bot.nearestVisibleCrewmate()
  if crewmate.found:
    let targetName = playerColorName(crewmate.sight.colorIndex)
    if bot.killReady and
        bot.inRange(crewmate.sight.x, crewmate.sight.y, KillRange):
      bot.intent = "kill " & targetName
      return bot.freshA()
    return bot.navigateToPoint(
      crewmate.sight.x,
      crewmate.sight.y,
      "shadow " & targetName
    )
  bot.randomRoam()

proc decideVotingMask(bot: var Bot): uint8 =
  ## Votes skip with edge-triggered navigation and action input.
  if bot.voteStartTick < 0:
    bot.voteStartTick = bot.frameTick
    bot.voteStep = 0
    bot.voteDone = false
  if bot.pendingChat.len > 0:
    bot.intent = "chatting body report"
    return 0
  if bot.voteDone:
    bot.intent = "vote done"
    return 0
  let listened = bot.frameTick - bot.voteStartTick
  if listened < VoteListenTicks:
    bot.intent = "listening vote chat"
    return 0
  let totalSteps = max(bot.visibleVoteCount(), VoteSkipSteps)
  if bot.voteStep < totalSteps:
    if bot.frameTick mod VoteSkipPulseGap == 0:
      inc bot.voteStep
      bot.intent = "voting cursor to skip"
      return ButtonRight
    bot.intent = "release vote cursor"
    return 0
  let mask = bot.freshA()
  bot.intent = "vote skip"
  if mask == ButtonA:
    bot.voteDone = true
  mask

proc decideNextMask(bot: var Bot): uint8 =
  ## Chooses the next input mask from semantic sprite protocol state.
  bot.analyzeObjects()
  bot.hasGoal = false
  if bot.interstitial:
    if bot.interstitialText.contains("SKIP"):
      result = bot.decideVotingMask()
      bot.desiredMask = result
      bot.controllerMask = result
      return
    bot.intent = "interstitial"
    bot.voteStartTick = -1
    bot.desiredMask = 0
    bot.controllerMask = 0
    return 0
  bot.voteStartTick = -1
  if bot.role == RoleImposter:
    result = bot.decideImposterMask()
  else:
    result = bot.decideCrewmateMask()
  bot.desiredMask = result
  bot.controllerMask = result

when defined(notsusGui):
  proc inputMaskSummary(mask: uint8): string =
    ## Returns a readable input mask description.
    var parts: seq[string] = @[]
    if (mask and ButtonUp) != 0:
      parts.add("up")
    if (mask and ButtonDown) != 0:
      parts.add("down")
    if (mask and ButtonLeft) != 0:
      parts.add("left")
    if (mask and ButtonRight) != 0:
      parts.add("right")
    if (mask and ButtonA) != 0:
      parts.add("a")
    if parts.len == 0:
      return "idle"
    parts.join(", ")

  const
    ViewerWindowWidth = 1820
    ViewerWindowHeight = 1060
    ViewerMargin = 16.0'f
    ViewerTitleY = 18.0'f
    ViewerLabelY = 66.0'f
    ViewerContentY = 108.0'f
    ViewerFrameScale = 4.0'f
    ViewerMapScale = 1.25'f
    ViewerWalkStep = 2
    ViewerBackground = rgbx(17, 20, 28, 255)
    ViewerPanel = rgbx(33, 38, 50, 255)
    ViewerPanelAlt = rgbx(22, 26, 36, 255)
    ViewerText = rgbx(226, 231, 240, 255)
    ViewerMutedText = rgbx(146, 155, 172, 255)
    ViewerWalk = rgbx(50, 68, 82, 255)
    ViewerBlocked = rgbx(94, 50, 58, 255)
    ViewerViewport = rgbx(142, 193, 255, 190)
    ViewerPlayer = rgbx(120, 255, 170, 255)
    ViewerGoal = rgbx(255, 132, 146, 255)
    ViewerPath = rgbx(119, 218, 255, 230)
    ViewerStep = rgbx(255, 220, 92, 255)
    ViewerTask = rgbx(255, 196, 88, 255)
    ViewerBody = rgbx(255, 84, 96, 255)
    ViewerCrew = rgbx(82, 168, 255, 255)
    ViewerTextSprite = rgbx(210, 210, 230, 255)

  proc drawOutline(
    sk: Silky,
    pos,
    size: Vec2,
    color: ColorRGBX,
    thickness = 1.0'f
  ) =
    ## Draws a rectangular outline.
    sk.drawRect(pos, vec2(size.x, thickness), color)
    sk.drawRect(
      vec2(pos.x, pos.y + size.y - thickness),
      vec2(size.x, thickness),
      color
    )
    sk.drawRect(pos, vec2(thickness, size.y), color)
    sk.drawRect(
      vec2(pos.x + size.x - thickness, pos.y),
      vec2(thickness, size.y),
      color
    )

  proc drawLine(sk: Silky, a, b: Vec2, color: ColorRGBX) =
    ## Draws a simple dotted line.
    let
      dx = b.x - a.x
      dy = b.y - a.y
      steps = max(1, int(max(abs(dx), abs(dy)) / 3.0'f))
    for i in 0 .. steps:
      let t = i.float32 / steps.float32
      sk.drawRect(
        vec2(a.x + dx * t - 1.0'f, a.y + dy * t - 1.0'f),
        vec2(3, 3),
        color
      )

  proc spriteDebugColor(kind: SpriteKind): ColorRGBX =
    ## Returns the overlay color for one sprite kind.
    case kind
    of SpriteTask, SpriteArrow:
      ViewerTask
    of SpriteBody:
      ViewerBody
    of SpritePlayer, SpriteGhost:
      ViewerCrew
    of SpriteText:
      ViewerTextSprite
    else:
      ViewerMutedText

  proc drawWalkabilityViewport(
    sk: Silky,
    bot: Bot,
    x,
    y,
    scale: float32
  ) =
    ## Draws the current screen viewport from the walkability mask.
    sk.drawRect(
      vec2(x, y),
      vec2(ScreenWidth.float32 * scale, ScreenHeight.float32 * scale),
      ViewerPanelAlt
    )
    if bot.walkMask.len == 0:
      return
    for sy in 0 ..< ScreenHeight:
      for sx in 0 ..< ScreenWidth:
        let
          mx = bot.cameraX + sx
          my = bot.cameraY + sy
          color =
            if mx >= 0 and my >= 0 and mx < bot.mapWidth and
                my < bot.mapHeight and
                bot.walkMask[bot.mapIndex(mx, my)]:
              ViewerWalk
            else:
              ViewerBlocked
        sk.drawRect(
          vec2(x + sx.float32 * scale, y + sy.float32 * scale),
          vec2(scale, scale),
          color
        )

  proc drawSpritePixelsClipped(
    sk: Silky,
    info: SpriteInfo,
    panelX,
    panelY: float32,
    objectX,
    objectY,
    clipW,
    clipH: int,
    scale: float32
  ): bool =
    ## Draws one decoded RGBA sprite clipped to the live viewport.
    if info.isNil or info.width <= 0 or info.height <= 0:
      return false
    if info.pixels.len != info.width * info.height * 4:
      return false
    let
      minPx = max(0, -objectX)
      minPy = max(0, -objectY)
      maxPx = min(info.width - 1, clipW - 1 - objectX)
      maxPy = min(info.height - 1, clipH - 1 - objectY)
    if minPx > maxPx or minPy > maxPy:
      return true
    for py in minPy .. maxPy:
      let dy = objectY + py
      for px in minPx .. maxPx:
        let
          pixelOffset = (py * info.width + px) * 4
          alpha = info.pixels[pixelOffset + 3].uint8
        if alpha == 0:
          continue
        let dx = objectX + px
        sk.drawRect(
          vec2(
            panelX + dx.float32 * scale,
            panelY + dy.float32 * scale
          ),
          vec2(scale, scale),
          rgbx(
            info.pixels[pixelOffset].uint8,
            info.pixels[pixelOffset + 1].uint8,
            info.pixels[pixelOffset + 2].uint8,
            alpha
          )
        )
    true

  proc orderedFrameObjectIds(bot: Bot): seq[int] =
    ## Returns current map-layer object ids in protocol draw order.
    for objectId, objectState in bot.objects:
      if objectState.present and objectState.layer == 0:
        result.add(objectId)
    result.sort(
      proc(a, b: int): int =
        let
          objectA = bot.objects[a]
          objectB = bot.objects[b]
        result = cmp(objectA.z, objectB.z)
        if result == 0:
          result = cmp(objectA.y, objectB.y)
        if result == 0:
          result = cmp(a, b)
    )

  proc drawFrameObjects(
    sk: Silky,
    bot: Bot,
    x,
    y,
    scale: float32
  ) =
    ## Draws decoded sprite objects over the live viewport.
    let objectIds = bot.orderedFrameObjectIds()
    for objectId in objectIds:
      let objectState = bot.objects[objectId]
      let info = bot.objectSprite(objectState)
      let kind = info.spriteKind()
      if kind == SpriteWalkability:
        continue
      let drewSprite = sk.drawSpritePixelsClipped(
        info,
        x,
        y,
        objectState.x,
        objectState.y,
        ScreenWidth,
        ScreenHeight,
        scale
      )
      if kind == SpriteMap or kind == SpriteScreen or
          info.spriteLabel() == "shadow":
        continue
      let
        outlineColor =
          if drewSprite:
            spriteDebugColor(kind)
          else:
            ViewerMutedText
        outlineThickness =
          if drewSprite:
            1.0'f
          else:
            2.0'f
      sk.drawOutline(
        vec2(
          x + objectState.x.float32 * scale,
          y + objectState.y.float32 * scale
        ),
        vec2(
          max(2, info.spriteWidth()).float32 * scale,
          max(2, info.spriteHeight()).float32 * scale
        ),
        outlineColor,
        outlineThickness
      )

  proc drawMapView(sk: Silky, bot: Bot, x, y: float32) =
    ## Draws full-map walkability, pathing, and semantic markers.
    sk.drawRect(
      vec2(x, y),
      vec2(bot.mapWidth.float32, bot.mapHeight.float32) * ViewerMapScale,
      ViewerPanelAlt
    )
    if bot.walkMask.len > 0:
      for my in countup(0, bot.mapHeight - 1, ViewerWalkStep):
        for mx in countup(0, bot.mapWidth - 1, ViewerWalkStep):
          let color =
            if bot.walkMask[bot.mapIndex(mx, my)]:
              ViewerWalk
            else:
              ViewerBlocked
          sk.drawRect(
            vec2(
              x + mx.float32 * ViewerMapScale,
              y + my.float32 * ViewerMapScale
            ),
            vec2(ViewerWalkStep.float32, ViewerWalkStep.float32) *
              ViewerMapScale,
            color
          )
    if bot.localized:
      sk.drawOutline(
        vec2(
          x + bot.cameraX.float32 * ViewerMapScale,
          y + bot.cameraY.float32 * ViewerMapScale
        ),
        vec2(ScreenWidth.float32, ScreenHeight.float32) * ViewerMapScale,
        ViewerViewport,
        1
      )
      sk.drawRect(
        vec2(
          x + bot.playerX.float32 * ViewerMapScale - 3,
          y + bot.playerY.float32 * ViewerMapScale - 3
        ),
        vec2(7, 7),
        ViewerPlayer
      )
    for target in bot.taskTargets:
      if target.found:
        sk.drawRect(
          vec2(
            x + target.x.float32 * ViewerMapScale - 4,
            y + target.y.float32 * ViewerMapScale - 4
          ),
          vec2(9, 9),
          ViewerTask
        )
    for body in bot.visibleBodies:
      sk.drawRect(
        vec2(
          x + body.x.float32 * ViewerMapScale - 4,
          y + body.y.float32 * ViewerMapScale - 4
        ),
        vec2(9, 9),
        ViewerBody
      )
    for player in bot.visiblePlayers:
      sk.drawOutline(
        vec2(
          x + player.x.float32 * ViewerMapScale - 4,
          y + player.y.float32 * ViewerMapScale - 4
        ),
        vec2(9, 9),
        if player.ghost: ViewerMutedText else: ViewerCrew,
        1
      )
    if bot.hasGoal:
      sk.drawRect(
        vec2(
          x + bot.goalX.float32 * ViewerMapScale - 5,
          y + bot.goalY.float32 * ViewerMapScale - 5
        ),
        vec2(11, 11),
        ViewerGoal
      )
    if bot.hasRoamGoal:
      sk.drawOutline(
        vec2(
          x + bot.roamGoalX.float32 * ViewerMapScale - 6,
          y + bot.roamGoalY.float32 * ViewerMapScale - 6
        ),
        vec2(13, 13),
        ViewerStep,
        2
      )
    if bot.path.len > 0 and bot.localized:
      var previous = vec2(
        x + bot.playerX.float32 * ViewerMapScale,
        y + bot.playerY.float32 * ViewerMapScale
      )
      for i in countup(0, bot.path.high, 6):
        let current = vec2(
          x + bot.path[i].x.float32 * ViewerMapScale,
          y + bot.path[i].y.float32 * ViewerMapScale
        )
        sk.drawLine(previous, current, ViewerPath)
        previous = current
      if bot.hasGoal:
        sk.drawLine(
          previous,
          vec2(
            x + bot.goalX.float32 * ViewerMapScale,
            y + bot.goalY.float32 * ViewerMapScale
          ),
          ViewerPath
        )
    if bot.pathStep.found:
      sk.drawRect(
        vec2(
          x + bot.pathStep.x.float32 * ViewerMapScale - 3,
          y + bot.pathStep.y.float32 * ViewerMapScale - 3
        ),
        vec2(7, 7),
        ViewerStep
      )

  proc refreshDisplayScale(viewer: ViewerApp) =
    ## Updates UI scaling after the window moves between displays.
    if viewer.isNil:
      return
    let scale = viewer.window.displayScale()
    if abs(scale - viewer.contentScale) <= 0.001'f:
      return
    viewer.contentScale = scale
    viewer.silky.uiScale = scale
    when not defined(emscripten):
      let logicalSize = (viewer.window.size.vec2 / scale).ivec2
      viewer.window.size = logicalSize.scaledWindowSize(scale)

  proc initViewerApp(): ViewerApp =
    ## Opens the notsus diagnostic viewer window.
    result = ViewerApp()
    result.window = newWindow(
      title = "Crewrift Bot Viewer",
      size = ivec2(ViewerWindowWidth, ViewerWindowHeight),
      style = Decorated,
      visible = true
    )
    makeContextCurrent(result.window)
    when not defined(useDirectX):
      loadExtensions()
    result.silky = newSilky(
      result.window,
      getCurrentDir() / "clients" / "dist" / "atlas.png"
    )
    result.contentScale = result.window.displayScale()
    result.silky.uiScale = result.contentScale
    when not defined(emscripten):
      result.window.size =
        ivec2(
          ViewerWindowWidth,
          ViewerWindowHeight
        ).scaledWindowSize(result.contentScale)
    let viewer = result
    result.window.onResize = proc() =
      viewer.refreshDisplayScale()

  proc viewerOpen(viewer: ViewerApp): bool =
    ## Returns true when the viewer is absent or open.
    viewer.isNil or not viewer.window.closeRequested

  proc pumpViewer(
    viewer: ViewerApp,
    bot: Bot,
    connected: bool,
    url: string
  ) =
    ## Pumps GUI events and renders one debugger frame.
    if viewer.isNil:
      return
    pollEvents()
    if viewer.window.buttonPressed[KeyEscape]:
      viewer.window.closeRequested = true
    if viewer.window.closeRequested:
      return
    viewer.refreshDisplayScale()
    let
      sk = viewer.silky
      frameSize = viewer.window.size
      contentScale = viewer.contentScale
      uiScale = sk.uiScale
      logicalSize = frameSize.vec2 / uiScale
      framePos = vec2(ViewerMargin, ViewerContentY)
      mapPos = vec2(
        framePos.x + ScreenWidth.float32 * ViewerFrameScale + 24,
        ViewerContentY
      )
      infoPos = vec2(
        ViewerMargin,
        framePos.y + ScreenHeight.float32 * ViewerFrameScale + 28
      )
      infoSize = vec2(logicalSize.x - ViewerMargin * 2, 320)
    sk.beginUI(viewer.window, frameSize)
    sk.clearScreen(ViewerBackground)
    discard sk.drawText(
      "Default",
      "Crewrift Bot Viewer",
      vec2(ViewerMargin, ViewerTitleY),
      ViewerText
    )
    sk.drawRect(
      framePos - vec2(8, 8),
      vec2(
        ScreenWidth.float32 * ViewerFrameScale + 16,
        ScreenHeight.float32 * ViewerFrameScale + 16
      ),
      ViewerPanel
    )
    sk.drawRect(
      mapPos - vec2(8, 8),
      vec2(
        bot.mapWidth.float32 * ViewerMapScale + 16,
        bot.mapHeight.float32 * ViewerMapScale + 16
      ),
      ViewerPanel
    )
    discard sk.drawText(
      "Default",
      "Live sprite view",
      vec2(framePos.x, ViewerLabelY),
      ViewerMutedText
    )
    discard sk.drawText(
      "Default",
      "Map lock",
      vec2(mapPos.x, ViewerLabelY),
      ViewerMutedText
    )
    sk.drawRect(infoPos - vec2(8, 8), infoSize + vec2(16, 16), ViewerPanel)
    sk.drawWalkabilityViewport(bot, framePos.x, framePos.y, ViewerFrameScale)
    sk.drawFrameObjects(bot, framePos.x, framePos.y, ViewerFrameScale)
    sk.drawRect(
      vec2(
        framePos.x + PlayerScreenX.float32 * ViewerFrameScale - 3,
        framePos.y + PlayerScreenY.float32 * ViewerFrameScale - 3
      ),
      vec2(7, 7),
      ViewerPlayer
    )
    sk.drawMapView(bot, mapPos.x, mapPos.y)
    let goalText =
      if bot.hasGoal:
        "goal: " & bot.goalName & " (" & $bot.goalX & ", " &
          $bot.goalY & ")"
      else:
        "goal: none"
    let
      playerWalkable =
        bot.localized and bot.passable(bot.playerX, bot.playerY)
      stepWalkable =
        bot.pathStep.found and bot.passable(bot.pathStep.x, bot.pathStep.y)
      segmentClear =
        bot.pathStep.found and bot.segmentPassable(
          bot.playerX,
          bot.playerY,
          bot.pathStep.x,
          bot.pathStep.y
        )
    let infoText =
      "status: " & (if connected: "connected" else: "reconnecting") & "\n" &
      "url: " & url & "\n" &
      "dpi: contentScale=" & $contentScale &
        " uiScale=" & $uiScale &
        " framebuffer=(" & $frameSize.x & ", " & $frameSize.y & ")" & "\n" &
      "intent: " & bot.intent & "\n" &
      "timing pathing: " & $bot.astarMicros & "us (" &
        $(bot.astarMicros div 1000) & "ms)\n" &
      "client tick: " & $bot.frameTick & "\n" &
      "BUTTONS HELD: " & inputMaskSummary(bot.lastMask) & "\n" &
      "role: " & (if bot.role == RoleImposter: "imposter" else: "crew") &
        " ghost=" & $bot.isGhost & " killReady=" & $bot.killReady & "\n" &
      "known imposters: " & bot.knownImposterSummary() & "\n" &
      "localized: " & $bot.localized &
        " camera=(" & $bot.cameraX & ", " & $bot.cameraY & ")" &
        " player=(" & $bot.playerX & ", " & $bot.playerY & ")" & "\n" &
      "velocity: (" & $bot.velocityX & ", " & $bot.velocityY & ")" &
        " stuck=" & $bot.stuckFrames &
        " jiggle=" & $bot.jiggleTicks & "\n" &
      "walkability: " & $bot.walkabilityReceived &
        " pixels=" & $bot.walkMask.len &
        " playerWalkable=" & $playerWalkable & "\n" &
      goalText & "\n" &
      "path pixels: " & $bot.path.len &
        " step=(" & $bot.pathStep.x & ", " & $bot.pathStep.y & ")" &
        " stepWalkable=" & $stepWalkable &
        " segmentClear=" & $segmentClear & "\n" &
      "roam: " & $bot.hasRoamGoal &
        " goal=(" & $bot.roamGoalX & ", " & $bot.roamGoalY & ")" &
        " ttl=" & $bot.roamGoalTicks & "\n" &
      "desired: " & inputMaskSummary(bot.desiredMask) & "\n" &
      "controller: " & inputMaskSummary(bot.controllerMask) & "\n" &
      "visible players=" & $bot.visiblePlayers.len &
        " bodies=" & $bot.visibleBodies.len &
        " tasks=" & $bot.taskTargets.len & "\n" &
      "interstitial: " & $bot.interstitial & " " &
        bot.interstitialText & "\n" &
      "pending chat: " & bot.pendingChat
    discard sk.drawText(
      "Default",
      infoText,
      infoPos,
      ViewerText,
      infoSize.x,
      infoSize.y
    )
    sk.endUi()
    viewer.window.swapBuffers()

when not defined(notsusGui):
  proc viewerOpen(viewer: ViewerApp): bool =
    ## Returns true for headless builds.
    true

proc acceptServerMessage(
  ws: WebSocket,
  message: Message,
  bot: var Bot,
  gui = false
): bool =
  ## Handles one websocket message and updates sprite state.
  case message.kind
  of BinaryMessage:
    if not bot.applySpritePacket(message.data, gui):
      fatal(
        "received malformed sprite protocol packet or invalid sprite payload"
      )
    inc bot.frameTick
    result = true
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot, gui = false): bool =
  ## Receives and applies all currently queued sprite protocol updates.
  let firstMessage = ws.receiveMessage(if gui: 10 else: -1)
  if firstMessage.isNone:
    return false
  if ws.acceptServerMessage(firstMessage.get, bot, gui):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone:
      break
    if ws.acceptServerMessage(message.get, bot, gui):
      result = true
    inc drained

proc initBot(): Bot =
  ## Builds a metadata-only sprite protocol bot.
  new(result)
  result.rng = initRand(getTime().toUnix() xor int64(getCurrentProcessId()))
  result.lastSeenTicks = newSeq[int](PlayerColorNames.len)
  result.knownImposterColors = newSeq[bool](PlayerColorNames.len)
  for item in result.lastSeenTicks.mitems:
    item = -1
  result.role = RoleCrewmate
  result.taskHoldIndex = -1
  result.selfJoinOrder = -1
  result.selfColorIndex = -1
  result.lastBodySeenX = low(int)
  result.lastBodySeenY = low(int)
  result.voteStartTick = -1

proc runBot(
  host = DefaultHost,
  port = PlayerDefaultPort,
  name = "",
  slot = "",
  token = "",
  url = "",
  gui = false
) =
  ## Connects to a Crewrift sprite player endpoint.
  when not defined(notsusGui):
    if gui:
      fatal("rebuild with -d:notsusGui to use --gui")
  var bot = initBot()
  let endpoint = playerUrl(host, port, name, slot, token, url)
  when defined(notsusGui):
    var viewer =
      if gui:
        initViewerApp()
      else:
        nil
  else:
    var viewer: ViewerApp = nil
  while viewer.viewerOpen():
    try:
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while viewer.viewerOpen():
        when defined(notsusGui):
          if gui:
            viewer.pumpViewer(bot, true, endpoint)
            if not viewer.viewerOpen():
              ws.close()
              break
        if not ws.receiveUpdates(bot, gui):
          continue
        let nextMask = bot.decideNextMask()
        bot.lastMask = nextMask
        if nextMask != lastMask:
          ws.send(playerInputBlob(nextMask), BinaryMessage)
          lastMask = nextMask
        if bot.interstitial and bot.pendingChat.len > 0 and
            bot.interstitialText.contains("SKIP"):
          ws.send(chatBlob(bot.pendingChat), BinaryMessage)
          bot.pendingChat = ""
    except CatchableError:
      when defined(notsusGui):
        if gui:
          let start = epochTime()
          while viewer.viewerOpen() and epochTime() - start < 0.25:
            viewer.pumpViewer(bot, false, endpoint)
            sleep(10)
        else:
          sleep(250)
      else:
        sleep(250)

when isMainModule:
  var
    address = DefaultHost
    port = PlayerDefaultPort
    name = ""
    slot = ""
    token = ""
    url = ""
    gui = false
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address":
        address = val
      of "port":
        port = parseInt(val)
      of "name":
        name = val
      of "slot":
        slot = val
      of "token":
        token = val
      of "url":
        url = val
      of "gui":
        gui = true
      else:
        discard
    else:
      discard
  runBot(address, port, name, slot, token, url, gui)
