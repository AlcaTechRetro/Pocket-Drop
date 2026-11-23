# Contributing to Pocket Drop

Thanks for helping! Bug reports, device test results and ideas are all welcome.

## Reporting a bug

Open an [issue](https://github.com/AlcaTechRetro/Pocket-Drop/issues/new/choose) and include:

- your handheld model and muOS version;
- what you did, what you expected and what happened;
- `log.txt` and `log-previous.txt` from `MUOS/application/PocketDrop/`. Your API key is hidden in them.

**Never** post your `drive_links.ini`, API key or private folder links.

## Testing on another device

If you run Pocket Drop on a handheld other than the RG35XX SP, open an issue titled
`Device report: <model>` saying whether it launched, browsed and downloaded correctly.

## Code

Pocket Drop is written in Lua for [LÖVE](https://love2d.org) 11.4.

| File | Purpose |
| --- | --- |
| `main.lua` | Screens, input and app flow |
| `worker.lua` | Background downloads (curl), parallel pieces, checks and unzip |
| `gdrive.lua` | Google Drive API helpers and error messages |
| `listing.lua` | Web folder and archive listing parsers |
| `util.lua` | Files, settings, logging and `.ini` handling |
| `consoles.lua` | The console list and `ROMS` folder names |
| `mux_launch.sh` | muOS launcher |

You can run it on a PC: install LÖVE 11.x and drag the `PocketDrop` folder onto it.
Downloads then go to `PocketDrop/TEST_ROMS`.

Pull requests should keep the app simple to use with a D-pad and four buttons.
Pocket Drop must never include, search for or link to copyrighted games.
