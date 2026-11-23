Pocket Drop 1.0 - for muOS on the Anbernic RG35XX SP
=====================================================

What it does
- Shows every console from NES to PSP (oldest first).
- Link each console to one of your Google Drive folders.
- Open a console, browse its folder, press A on a file: it downloads straight
  into the right ROMS folder (e.g. ROMS/GBA) and unzips it. One click.
Only use files you have the right to use (e.g. copies of your own cartridges).

1. Link your consoles - the easy way: drive_links.ini
   Open drive_links.ini (in this folder) on your PC with Notepad++ or Notepad.
   - Paste your Google API key after  api_key =
   - Paste the share link of each console's Drive folder after its  =
     e.g.  GBA = https://drive.google.com/drive/folders/1AbC...?usp=sharing
     Leave a console empty if you don't use it.
     (Drive: right-click the folder -> Share -> "Anyone with the link"
      (Viewer) -> Copy link)
   - Save, then copy the PocketDrop folder to the console.
   How to get the key: GOOGLE-DRIVE-SETUP.txt.

   You can also link on the device: highlight a console and press X
   (or A if it isn't linked yet), paste/type the link. The app writes it
   into drive_links.ini for you. X on a linked console: Change / Remove.
   A console showing "check link" in red has a link that isn't a Drive
   folder link - fix it in drive_links.ini and press Y.

2. Try it on your PC (optional)
   Install LOVE 11.4 from love2d.org, then drag this PocketDrop folder onto
   love.exe (Windows) or the LOVE app (Mac). Files go into PocketDrop/TEST_ROMS.
   Keys: arrows = D-pad, Enter = A, Backspace = B, X = X, Y = Y, Q/E = L1/R1.

3. Put it on the handheld
   - Power off and put SD card 1 (TF1) in your card reader.
   - Copy the whole PocketDrop folder into MUOS/application/
     so you have MUOS/application/PocketDrop/mux_launch.sh
   - Put the card back, power on, connect to Wi-Fi,
     then Applications -> Pocket Drop.

Where downloads go
   On start, Pocket Drop creates a folder in ROMS for every console listed
   below if it's missing (existing folders and games are never touched).
   NES, MS, PCE, MD, GB, LYNX, NEOGEO, GG, SNES, SEGACD, 32X, SATURN, PS, VB,
   N64, GBC, DC, NGPC, WSC, GBA, NDS, PSP  (inside your ROMS folder).
   muOS recognises these names and picks the emulator itself. If it ever
   asks, choose the system once for that folder.
   To use another folder name, add to sites.ini, e.g.
       [Super Nintendo]
       folder = SFC

Buttons
   A open / download      B back      X link/change      Y refresh
   L1/R1 page up/down     Start + Select quit
   Settings -> Button test checks every button (hold B 2 s to leave).

If the buttons don't work
   Pocket Drop asks you to press each button once (Button setup). You can
   redo it in Settings -> Button setup.

If the app closes straight away
   Open MUOS/application/PocketDrop/log.txt and launch.txt on the SD card.
   log-previous.txt has the session before that.
   - "LOVE was not found": your muOS has no LOVE. Put an aarch64 LOVE 11.4
     build in PocketDrop/bin/ (bin/love + bin/libs/).
   - Anything else: send log.txt and launch.txt (your API key is hidden).
   If the app shows a red "hit a problem" screen, press any button to exit;
   the details are in log.txt.

Other sources (optional, advanced)
   sites.ini also accepts plain web folder listings and Internet Archive
   items you have the right to use, e.g.
       [Game Boy Advance]
       source = Gleam (homebrew) | https://archive.org/download/05dcfc-15-0682-4a-82-abbf-ec-2993bfc-699

Faster downloads (Settings)
- Connections per download (1 / 2 / 4, default 4): big files (4 MB+) are
  fetched as several pieces at once and joined. On weak Wi-Fi this is often
  much faster. If a server doesn't allow it, one connection is used.
- Speed boost while downloading (default ON): CPU at full speed and Wi-Fi
  power saving off during a download; both are put back afterwards.
- The screen redraws less while downloading, leaving the CPU for the download.

Downloads are kept off the SD card until they're finished
- Files that fit in the console's free memory (most games up to ~190 MB) are
  downloaded into memory first. Only the finished, checked file is written
  to the SD card, in one step. Bigger files use a hidden ".partial" folder.
- B during a download -> "Cancel download": the unfinished download is
  deleted. A download that fails is deleted automatically too.
- If the connection drops or stalls, Pocket Drop reconnects by itself.
- The RG35XX SP's Wi-Fi is often faster and steadier on a 2.4 GHz,
  WPA2-only network.

Safety
- Every finished download from Google Drive or Internet Archive is checked
  against the file's published fingerprint (MD5). A damaged download is
  deleted and reported, never saved as a broken game.
- After each download, Stop and quit, Pocket Drop writes everything to the
  SD card straight away, so switching off afterwards can't damage files.
- Quit with Start + Select (or B on the home screen) instead of holding the
  power button. Holding power while files are being written can damage the
  SD card's files.
- On every start the launcher checks the LOVE engine files; if they're
  damaged, log.txt says so (copy the bin folder again).

Notes
- Keep the lid open while downloading; closing it sleeps the console.
- If a file already exists you'll be asked whether to replace it.
- Settings: unzip on/off, delete the zip after unzipping, which SD card's
  ROMS folder to use, Google API key.
