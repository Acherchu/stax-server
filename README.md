# Stax server

The online game server for [Stax](https://acherchu.github.io/stax/). Like Roblox's servers: every
player's game connects here, and the server runs the games everyone shares (Zombie Night's horde
and waves, Blocky Kart's rounds and computer drivers) and passes players' movements to each other.
No player's PC is "the host".

- `stax-server.pck` - the game, packed (built from the Stax project with `--export-pack`).
- `Dockerfile` - downloads Godot 4.7.2 for Linux and runs the pack with `--server`.
- `render.yaml` - how Render runs it (free web service).

**Start it on Render:** [Deploy to Render](https://render.com/deploy?repo=https://github.com/Acherchu/stax-server)
(sign in with GitHub, then *Apply*). Players find the server through
`https://acherchu.github.io/stax/server.json`, so if Render gives it a different address, only that
file needs changing.

**Update it:** export a new `stax-server.pck` from the Stax project, commit and push - Render rebuilds
by itself. The server and the players' games must have the same `Net.PROTOCOL`.

On the free plan the server sleeps after 15 minutes with nobody online; the first player to start a
game wakes it up (up to a minute - Stax shows "Connecting to the Stax server...").
