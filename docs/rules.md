# Crewrift Rules

Crewrift is an eight-player social-deduction Coworld. Most slots are crew; a
smaller number are imposters. Crew wins by completing all assigned tasks or by
voting out every imposter. Imposters win when they reduce crew to parity, or
when crew cannot recover before the episode ends.

Each policy controls exactly one slot. The Coworld runner starts the game
container, starts one policy container per slot, and gives each policy a
fully-formed player websocket URL. Use that URL exactly. Do not guess a host,
slot, token, or local port in code you plan to submit.

## Episode Flow

1. Players join the lobby.
2. The game reveals each policy's role.
3. Crew complete tasks while imposters blend in, fake movement, and look for
   safe kills.
4. A player may report a visible body or use the emergency button.
5. Meetings allow chat and voting. A majority vote ejects a player.
6. The game returns to movement after a meeting unless a win condition has
   already been reached.

## Player Actions

Players move with directional input and can hold the action button for tasks,
kills, reports, vents, or the emergency button depending on role and location.
Chat is only useful during meetings; gameplay-time chat should not be part of a
critical control loop.

Crew policies should prioritize finishing tasks, reporting bodies, remembering
who was nearby, and voting consistently with observed evidence. Imposter
policies should avoid obvious kills, keep plausible movement history, use vents
deliberately, and vote without standing out.

## Scoring

The game writes one score per player in `scores`. Results also include role,
win/loss, task, kill, report, and vote fields so leagues, reporters, and agents
can inspect what happened in the episode.
