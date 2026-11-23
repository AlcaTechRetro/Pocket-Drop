-- consoles.lua
-- The console sections shown on the home screen, oldest first (NES -> PSP).
-- "folder" is the folder inside ROMS where downloads are saved. These are
-- common short names that muOS recognises, so it picks the emulator itself.
-- (If it ever doesn't, muOS asks once which system the folder is for.)
-- To use a different folder for a console, add to sites.ini, e.g.:
--   [Game Boy Advance]
--   folder = Game Boy Advance

return {
  { name = "Nintendo Entertainment System", short = "NES",    folder = "NES",    year = 1983 },
  { name = "Sega Master System",            short = "SMS",    folder = "MS",     year = 1985 },
  { name = "PC Engine / TurboGrafx-16",     short = "PCE",    folder = "PCE",    year = 1987 },
  { name = "Sega Mega Drive / Genesis",     short = "MD",     folder = "MD",     year = 1988 },
  { name = "Game Boy",                      short = "GB",     folder = "GB",     year = 1989 },
  { name = "Atari Lynx",                    short = "Lynx",   folder = "LYNX",   year = 1989 },
  { name = "Neo Geo",                       short = "NeoGeo", folder = "NEOGEO", year = 1990 },
  { name = "Sega Game Gear",                short = "GG",     folder = "GG",     year = 1990 },
  { name = "Super Nintendo",                short = "SNES",   folder = "SNES",   year = 1990 },
  { name = "Sega CD / Mega-CD",             short = "SegaCD", folder = "SEGACD", year = 1991 },
  { name = "Sega 32X",                      short = "32X",    folder = "32X",    year = 1994 },
  { name = "Sega Saturn",                   short = "Saturn", folder = "SATURN", year = 1994 },
  { name = "Sony PlayStation",              short = "PS1",    folder = "PS",     year = 1994 },
  { name = "Virtual Boy",                   short = "VB",     folder = "VB",     year = 1995 },
  { name = "Nintendo 64",                   short = "N64",    folder = "N64",    year = 1996 },
  { name = "Game Boy Color",                short = "GBC",    folder = "GBC",    year = 1998 },
  { name = "Sega Dreamcast",                short = "DC",     folder = "DC",     year = 1998 },
  { name = "Neo Geo Pocket Color",          short = "NGPC",   folder = "NGPC",   year = 1999 },
  { name = "WonderSwan Color",              short = "WSC",    folder = "WSC",    year = 2000 },
  { name = "Game Boy Advance",              short = "GBA",    folder = "GBA",    year = 2001 },
  { name = "Nintendo DS",                   short = "NDS",    folder = "NDS",    year = 2004 },
  { name = "Sony PSP",                      short = "PSP",    folder = "PSP",    year = 2004 },
}
