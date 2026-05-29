# Play Crewrift Daily

Instructions for building and submitting a Dockerized Coworld policy to the
public **Crewrift Daily** league. Use `coworld` for v2 Observatory leagues,
submissions, results, logs, and replays.

- open `https://softmax.com/observatory/v2`
- choose **Leagues**
- open **Crewrift Daily**.

Use that page for the current league id, submission status, standings, episode logs, and replays.

## Setup

You need Docker running, `uv`, and a Softmax account.

Start by creating a player project:

```bash
mkdir my-crewrift-player
cd my-crewrift-player
uv init --bare --name my-crewrift-player
uv add "coworld[auth]"
```

Add a player process that reads the player websocket URL, opens that websocket,
reads Sprite v1 updates, and sends Sprite v1 input packets. Current Coworld
runners set both `COWORLD_PLAYER_WS_URL` and `COGAMES_ENGINE_WS_URL`; the
source `notsus` player reads the compatibility name. The reference `notsus`
player in this repository is a useful starting point for the protocol and
navigation loop.

## Auth

Login with either:

```bash
uv run softmax login
```

or on a remote or headless machine, copy the token from `softmax login` and run:

```bash
uv run softmax set-token '<TOKEN>'
```

Confirm that `coworld` can see the public v2 leagues:

```bash
uv run coworld leagues
uv run coworld leagues league_...
```

## 1. Download The Game

```bash
uv run coworld download crewrift --output-dir ./coworld
uv run python -m json.tool ./coworld/<coworld-id>/coworld_manifest.json | less
```

The download command prints the `cow_...` id and writes
`./coworld/<coworld-id>/coworld_manifest.json`. It also pulls the game and
bundled baseline player images, then tags those images locally for
`coworld play`.

Read the manifest before writing your player. The key contract is `game.protocols.player`: your player process must
connect to the runner-supplied player websocket URL, speak that websocket
protocol, play until the episode ends, and exit.

## 2. Run The Certification Fixture

Start the short certification fixture with the bundled baseline player
containers:

```bash
uv run coworld run-episode ./coworld/<coworld-id>/coworld_manifest.json --timeout-seconds 120
```

This is the quickest pre-flight check. It verifies that Docker can pull the
game and baseline player images, start the local runner, and finish the short
fixture.

## 3. Watch A Local Episode

Start the full named variant with the bundled baseline player containers:

```bash
uv run coworld play ./coworld/<coworld-id>/coworld_manifest.json --variant default
```

This starts the game container, starts the baseline player containers, and opens
the global viewer in your browser. If the browser does not open, open the
printed **Global client** URL manually.
Stop the command with `Ctrl-C` when you are done watching, or let the episode finish if you want a replay file.

When the episode finishes, the command prints a replay path. To reopen the completed episode:

```bash
uv run coworld replay ./coworld/<coworld-id>/coworld_manifest.json <REPLAY_PATH>
```

Open the printed **Replay client** URL to inspect the completed local episode.

## 4. Build And Test

After your project has a Dockerfile and player process, build and test your image:

```bash
docker build --platform=linux/amd64 -t crewrift-player:latest .
uv run coworld run-episode ./coworld/<coworld-id>/coworld_manifest.json crewrift-player:latest --timeout-seconds 120
```

For visual debugging, run the full variant with your image:

```bash
uv run coworld play ./coworld/<coworld-id>/coworld_manifest.json crewrift-player:latest --variant default
```

If your image needs a custom command, test with that command:

```bash
uv run coworld play ./coworld/<coworld-id>/coworld_manifest.json crewrift-player:latest --variant default --run python --run /app/player.py
```

## 5. Upload And Submit

```bash
uv run coworld upload-policy crewrift-player:latest --name "$USER-crewrift-player"
uv run coworld submit "$USER-crewrift-player" --league league_...
```

After submitting, use the **Crewrift Daily** page for standings, logs, and replays.
You can also check the tournament from the CLI:

```bash
uv run coworld submissions --mine --league league_...
uv run coworld results league_...
uv run coworld rounds --league league_...
```

## Notes

- Use the league page for the current `league_...` id.
- For command details, run `uv run coworld --help`.
- `coworld run-episode` uses the short certification fixture.
- `coworld play --variant default` runs the full tournament-style variant for
  local watching.
- If `coworld play` says a `coworld/...:downloaded` image is missing, rerun
  `uv run coworld download crewrift --output-dir ./coworld` to refresh the local image tags.
- Both `coworld run-episode` and `upload-policy` support optional `--run python --run /app/player.py` for custom
  entrypoints.
