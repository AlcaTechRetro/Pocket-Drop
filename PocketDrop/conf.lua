-- conf.lua: window settings. On the handheld we go fullscreen; on a PC we
-- open a normal 640x480 window for testing.
function love.conf(t)
  local onDevice = os.rename("/opt/muos", "/opt/muos") and true or false
  t.identity = "PocketDrop"
  t.version = "11.4"
  t.window.title = "Pocket Drop"
  t.window.width = 640
  t.window.height = 480
  t.window.fullscreen = onDevice
  t.window.vsync = 1
  t.modules.physics = false
  t.modules.video = false
  t.modules.audio = false   -- the app makes no sound: skip the audio system
  t.modules.sound = false
end
