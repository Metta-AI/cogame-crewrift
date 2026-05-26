import
  std/[os, strutils],
  curly,
  crewrift/common/protocol,
  crewrift/sim,
  crewrift/server

proc cogamePath(value, source: string): string =
  if value.len == 0:
    return ""
  const FilePrefix = "file://"
  if value.startsWith(FilePrefix):
    result = value[FilePrefix.len .. ^1]
    if result.len == 0:
      echo "ERROR: empty file URI from " & source
      quit(1)
    return
  if "://" in value:
    return ""
  result = value

proc isHttpUri(uri: string): bool =
  uri.startsWith("http://") or uri.startsWith("https://")

when isMainModule:
  let
    address = getEnv("COGAME_HOST", DefaultHost)
    port = parseInt(getEnv("COGAME_PORT", $DefaultPort))
    configUri = getEnv("COGAME_CONFIG_URI")
    configPath = cogamePath(configUri, "COGAME_CONFIG_URI")
    saveReplayUri = getEnv("COGAME_SAVE_REPLAY_URI")
    saveScoresUri = getEnv("COGAME_RESULTS_URI")
    loadReplayUri = getEnv("COGAME_LOAD_REPLAY_URI")
    localReplayPath =
      if isHttpUri(saveReplayUri): "/tmp/crewrift_replay.bitreplay"
      else: cogamePath(saveReplayUri, "COGAME_SAVE_REPLAY_URI")
    localScoresPath =
      if isHttpUri(saveScoresUri): "/tmp/crewrift_scores.json"
      else: cogamePath(saveScoresUri, "COGAME_RESULTS_URI")
    loadReplayPath = cogamePath(loadReplayUri, "COGAME_LOAD_REPLAY_URI")
    replayServerMode = getEnv("COGAME_REPLAY_SERVER") == "1"
    replayDownloadUrl = getEnv("REPLAY_DOWNLOAD_URL")

  var config = defaultGameConfig()
  if configPath.len > 0:
    config.update(readFile(configPath))
  elif isHttpUri(configUri):
    let pool = newCurlPool(1)
    let resp = pool.get(configUri)
    if resp.code == 200:
      config.update(resp.body)
    else:
      echo "ERROR: config download failed: ", resp.code
      quit(1)
  echo "Using map file: " & config.mapPath

  var actualLoadReplayPath = loadReplayPath
  if replayDownloadUrl.len > 0 and actualLoadReplayPath.len == 0 and
      not replayServerMode:
    echo "Downloading replay from: ", replayDownloadUrl
    let pool = newCurlPool(1)
    let resp = pool.get(replayDownloadUrl)
    if resp.code != 200:
      echo "ERROR: replay download failed: ", resp.code
      quit(1)
    actualLoadReplayPath = "/tmp/downloaded.bitreplay"
    writeFile(actualLoadReplayPath, resp.body)
    echo "Replay downloaded: ", resp.body.len, " bytes"

  echo "starting crewrift on ", address, ":", port
  runServerLoop(
    address,
    port,
    config,
    localReplayPath,
    actualLoadReplayPath,
    localScoresPath,
    replayServerMode,
    saveReplayUri,
    saveScoresUri
  )
