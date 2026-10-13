local Settings = require("ddc.settings")
local test, eq, ok = T.test, T.eq, T.ok

test("settings: round trip", function()
  local s = Settings.defaults()
  s.mode, s.max, s.invert_x, s.lang = "gyro", 26, true, "en"
  local back = Settings.parse(Settings.serialize(s))
  for k in pairs(Settings.SPEC) do eq(back[k], s[k], k) end
end)

test("settings: garbage, unknown keys and bad values fall back to defaults", function()
  local d = Settings.defaults()
  local s = Settings.parse("v=9\nmode=warp\nmax=999\ndead=-1\ncurve=nan\nfuture=1\ninvert_y=yes\n\0junk")
  for k in pairs(Settings.SPEC) do eq(s[k], d[k], k) end
  s = Settings.parse(nil)
  eq(s.mode, "fused")
end)

test("settings: step wraps enums and clamps numbers on the grid", function()
  local s = Settings.defaults()
  Settings.step(s, "mode", -1)
  eq(s.mode, "touch")
  Settings.step(s, "mode", 1)
  eq(s.mode, "fused")
  s.smooth = 0.24
  Settings.step(s, "smooth", 1)
  eq(s.smooth, 0.24)
  for _ = 1, 20 do Settings.step(s, "smooth", -1) end
  eq(s.smooth, 0)
  Settings.step(s, "invert_x", 1)
  eq(s.invert_x, true)
  for _ = 1, 4 do Settings.step(s, "curve", 1) end
  ok(math.abs(s.curve - 2.2) < 1e-9, "curve " .. s.curve)
end)

test("settings: best score", function()
  eq(Settings.parse_best(Settings.serialize_best(1234)), 1234)
  eq(Settings.parse_best("garbage"), 0)
  eq(Settings.parse_best(nil), 0)
end)

test("version: the title screen shows manifest.json's version", function()
  local f = assert(io.open("app/manifest.json"))
  local manifest = f:read("a")
  f:close()
  eq(require("ddc.version"), manifest:match('"version"%s*:%s*"([^"]+)"'))
end)
