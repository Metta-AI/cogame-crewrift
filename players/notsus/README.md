# notsus

Run the bot headless:

```sh
nim r players/notsus/notsus.nim -- --address:127.0.0.1 --port:8080 --name:notsus
```

Run one bot with the pathing debugger:

```sh
nim r -d:notsusGui players/notsus/notsus.nim -- --gui --address:127.0.0.1 --port:8080 --name:notsus-debug
```

The debugger shows the sprite viewport, the decompressed walkability mask, the
current viewport rectangle, player position, visible objects, current goal,
roam goal, A* path, selected path step, input mask, velocity, and stuck state.
It scales the Silky UI from the current Windy backing size each frame, so moving
the window between high-DPI and low-DPI screens keeps the layout readable.
