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
    echo "ERROR: unsupported URI from " & source & ": " & value
    quit(1)
  result = value

when isMainModule:
  let
    address = getEnv("COGAME_HOST", DefaultHost)
    port = parseInt(getEnv("COGAME_PORT", $DefaultPort))
    configPath = cogamePath(getEnv("COGAME_CONFIG_URI"), "COGAME_CONFIG_URI")
    saveReplayPath = cogamePath(getEnv("COGAME_SAVE_REPLAY_URI"), "COGAME_SAVE_REPLAY_URI")
    loadReplayPath = cogamePath(getEnv("COGAME_LOAD_REPLAY_URI"), "COGAME_LOAD_REPLAY_URI")
    saveScoresPath = cogamePath(getEnv("COGAME_RESULTS_URI"), "COGAME_RESULTS_URI")
    replayServerMode = getEnv("COGAME_REPLAY_SERVER") == "1"
    replayDownloadUrl = getEnv("REPLAY_DOWNLOAD_URL")

  var config = defaultGameConfig()
  if configPath.len > 0:
    config.update(readFile(configPath))
  echo "Using map file: " & config.mapPath
  if configPath.len > 0:
    echo "Using config file: " & configPath

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

  if actualLoadReplayPath.len > 0:
    echo "Using replay load file: " & actualLoadReplayPath
  if saveReplayPath.len > 0:
    echo "Using replay save file: " & saveReplayPath
  if saveScoresPath.len > 0:
    echo "Using results save file: " & saveScoresPath

  echo "starting crewrift on ", address, ":", port
  runServerLoop(
    address,
    port,
    config,
    saveReplayPath,
    actualLoadReplayPath,
    saveScoresPath,
    replayServerMode
  )
