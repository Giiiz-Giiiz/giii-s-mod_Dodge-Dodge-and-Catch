-- Dodge-Dodge-and-Catch: tilt the device to fly a ship through falling meteors, catch
-- barriers and stars. Rules: ddc/world.lua, tilt pipeline: ddc/tilt.lua.
local World = require("ddc.world")
local Tilt = require("ddc.tilt")
local Settings = require("ddc.settings")
local STR = require("ddc.strings")
local R = require("ddc.render")
local VERSION = require("ddc.version")

-- Start each GC cycle at 1.5x the live heap (default 2x) so the peak stays well inside
-- the memory budget instead of hitting it and forcing an emergency collection mid-frame.
collectgarbage("incremental", 150, 200)

local gfx = giii.gfx
R.init(gfx)

local TICK_US = 1000000 // World.HZ
local MAX_STEPS = 8 -- per frame; a longer stall is dropped, not fast-forwarded
local COUNTDOWN_US = 3000000
local CAL_SKIP_US = 4000000
local NO_SAMPLE_US = 2000000

local cfg = Settings.parse(giii.storage.load("settings"))
local best = Settings.parse_best(giii.storage.load("best"))
local function T() return STR[cfg.lang] end

local tilt = Tilt.new({mode = cfg.mode ~= "touch" and cfg.mode or "fused"})
local imu = {accel = nil, gyro = nil, missing = nil}
local snd

local state, prev_state = nil, nil
local now, last_t, frame_us = 0, nil, 0
local world, acc_us, steps_last = nil, 0, 0
local ux, uy = 0, 0
local touch_target
local countdown_us = 0
local state_t0 = 0
local pause_reason
local toast, toast_until = nil, 0
local fx = {}
local frames = 0
local result = nil
local need_center = false -- IMU switched on from settings: take the grip once it reads

local function log(fmt, ...) print(fmt:format(...)) end

local function save_settings()
  local ok, err = giii.storage.save("settings", Settings.serialize(cfg))
  if not ok then log("WARN settings not saved: %s", tostring(err)) end
end

local function show(msg)
  toast, toast_until = msg, now + 1500000
end

-- sensors -----------------------------------------------------------------------------------

local function touch_mode() return cfg.mode == "touch" or imu.missing ~= nil end

local function close_sensors()
  if imu.accel then giii.sensors.close(imu.accel) end
  if imu.gyro then giii.sensors.close(imu.gyro) end
  imu.accel, imu.gyro = nil, nil
end

-- A missing IMU stays missing until the player picks an input mode again, so a resume
-- never silently switches a touch game back to tilt.
local function open_sensors()
  if cfg.mode == "touch" or imu.accel or imu.missing then return end
  local a, err = giii.sensors.open("accel", 100)
  local g, err2 = giii.sensors.open("gyro", 100)
  if not a or not g then
    if a then giii.sensors.close(a) end
    if g then giii.sensors.close(g) end
    imu.missing = tostring(err or err2)
    log("WARN imu unavailable: %s", imu.missing)
    return
  end
  imu.missing = nil
  imu.accel, imu.gyro = a, g
  tilt:reset()
end

local function record(kind, s)
  if cfg.rec then log("IMU %d %d %.5f %.5f %.5f 0", s.t_us, kind, s.x, s.y, s.z) end
end

local function read_sensors()
  if not imu.accel then return end
  local a = giii.sensors.read(imu.accel)
  local g = giii.sensors.read(imu.gyro)
  -- feed in timestamp order
  if a and g and a.t_us < g.t_us then
    if tilt:feed_accel(a) then record(1, a) end
    if tilt:feed_gyro(g) then record(2, g) end
  else
    if g and tilt:feed_gyro(g) then record(2, g) end
    if a and tilt:feed_accel(a) then record(1, a) end
  end
end

local function tilt_ok()
  return touch_mode() or tilt:status(now) == "ok"
end

-- logical input -----------------------------------------------------------------------------

local function update_input(dt_us)
  local tx, ty = 0, 0
  if touch_mode() then
    if touch_target and world then
      tx = math.max(-1, math.min(1, (touch_target.x - world.ship.x) / 24))
      ty = math.max(-1, math.min(1, (touch_target.y - world.ship.y) / 24))
    end
  elseif tilt:status(now) == "ok" then
    local rx, ry = tilt:relative()
    tx, ty = Tilt.shape(rx, cfg), Tilt.shape(ry, cfg)
  end
  if cfg.axes == "x" then ty = 0 end
  if cfg.invert_x then tx = -tx end
  if cfg.invert_y then ty = -ty end
  if cfg.smooth > 0 and not touch_mode() then
    local k = 1 - math.exp(-(dt_us * 1e-6) / cfg.smooth)
    ux, uy = ux + (tx - ux) * k, uy + (ty - uy) * k
  else
    ux, uy = tx, ty
  end
end

-- sound -------------------------------------------------------------------------------------

local function beep(...)
  if not cfg.sound then return end
  if not snd then
    snd = giii.audio.open(22050, 1)
    if not snd then cfg.sound = false return end
  end
  local notes = {...}
  for i = 1, #notes, 2 do giii.audio.tone(snd, notes[i], notes[i + 1], 0.35) end
end

-- states ------------------------------------------------------------------------------------

local function go(name)
  if state ~= "settings" then prev_state = state end
  state = name
  state_t0 = now
  log("STATE %s", name)
end

local function burst(x, y, c, n)
  for _ = 1, n do
    local a = math.random() * 2 * math.pi
    local v = 30 + math.random() * 90
    fx[#fx + 1] = {x = x, y = y, vx = math.cos(a) * v, vy = math.sin(a) * v, life = 0.6, c = c}
  end
end

local function new_run()
  local seed = math.random(1, 0x7FFFFFFF)
  world = World.new(seed)
  acc_us = 0
  fx = {}
  result = nil
  log("RUN seed=%d mode=%s", seed, touch_mode() and "touch" or cfg.mode)
  countdown_us = COUNTDOWN_US
  go("countdown")
end

local function pause(reason)
  pause_reason = reason
  touch_target = nil
  go("pause")
end

local function finish()
  local s = world.score
  local is_best = s > best
  if is_best then
    best = s
    local ok, err = giii.storage.save("best", Settings.serialize_best(best))
    if not ok then log("WARN best not saved: %s", tostring(err)) end
  end
  result = {score = s, best = is_best, secs = world.tick / World.HZ}
  log("OVER score=%d tick=%d digest=%s barrier=%d star=%d absorbed=%d", s, world.tick,
      world:digest(), world.stats.barrier, world.stats.star, world.stats.absorbed)
  go("over")
end

local function recenter()
  if touch_mode() then return end
  if tilt:recenter() then
    ux, uy = 0, 0
    show(T().recentered)
    log("RECENTER")
  end
end

local function on_event(e)
  log("EV %d %s %s", e.tick, e.kind, tostring(e.a))
  if e.kind == "catch" then
    if e.a == "barrier" then beep(660, 60, 990, 90) else beep(1320, 50) end
    burst(world.ship.x, world.ship.y, e.a == "barrier" and R.C.shield or R.C.gold, 8)
  elseif e.kind == "absorb" then
    beep(300, 60, 200, 80)
    burst(e.a, e.b, R.C.shield, 14)
  elseif e.kind == "expire" then
    beep(440, 60, 330, 80)
  elseif e.kind == "hit" then
    beep(160, 120, 90, 260)
    burst(world.ship.x, world.ship.y, R.C.warn, 24)
  elseif e.kind == "wall" then
    beep(180, 40)
  end
end

local function step_world()
  acc_us = acc_us + frame_us
  local n = 0
  while acc_us >= TICK_US and n < MAX_STEPS and not world.over do
    world:step(ux, uy)
    acc_us = acc_us - TICK_US
    n = n + 1
    if world.tick % 60 == 0 then
      log("STAT tick=%d score=%d x=%.1f y=%.1f ux=%.2f uy=%.2f shield=%d meteors=%d kb=%.0f",
          world.tick, world.score, world.ship.x, world.ship.y, ux, uy, world.shield.charges,
          #world.meteors, collectgarbage("count"))
    end
  end
  if n == MAX_STEPS then acc_us = 0 end
  steps_last = n
  world:drain_events(on_event)
  if world.over then finish() end
end

-- drawing -----------------------------------------------------------------------------------

local function diag_lines()
  local t = T()
  local ga, aa = tilt:age_ms(now)
  local g, a = tilt.gyro, tilt.accel
  local up = tilt.up or {0, 0, 0}
  local ar, ap = tilt:absolute()
  local rr, rp = tilt:relative()
  local lines = {
    ("%s %s bias %s"):format(touch_mode() and "touch" or cfg.mode, tilt:status(now),
                             tilt.bias_ok and "ok" or t.bias_unconfirmed),
    g and ("gyro %+.2f %+.2f %+.2f age %.0f"):format(g.x, g.y, g.z, ga or -1) or "gyro -",
    a and ("acc %+.1f %+.1f %+.1f age %.0f"):format(a.x, a.y, a.z, aa or -1) or "acc -",
    ("up %+.2f %+.2f %+.2f abs %+.0f %+.0f"):format(up[1], up[2], up[3], ar, ap),
    ("rel %+.1f %+.1f u %+.2f %+.2f"):format(rr, rp, ux, uy),
    ("frame %.1fms steps %d gaps %d miss %d"):format(frame_us / 1000, steps_last, tilt.gaps,
                                                     (g and g.missed or 0) + (a and a.missed or 0)),
  }
  return lines
end

local function draw_settings()
  local t = T()
  R.backdrop(0)
  gfx.fill(0, 0, 320, 20, R.C.hud)
  gfx.text(6, 4, t.settings, R.C.white)
  R.button("back", 252, 1, 64, 18, t.back)
  for i, k in ipairs(Settings.ORDER) do
    local y = 22 + (i - 1) * 18
    local v = cfg[k]
    local label
    if type(v) == "boolean" then
      label = v and t.v_on or t.v_off
    elseif type(v) == "number" then
      label = k == "smooth" and ("%.2f s"):format(v) or k == "curve" and ("%.1f"):format(v)
              or ("%d°"):format(math.floor(v + 0.5))
    else
      label = t["v_" .. v] or v
    end
    R.zone("inc:" .. k, 0, y, 244, 18) -- the whole row steps forward
    gfx.text(8, y + 3, t["s_" .. k], R.C.dim)
    gfx.text(124, y + 3, label, R.C.white)
    R.button("dec:" .. k, 246, y, 32, 17, "<")
    R.button("inc:" .. k, 284, y, 32, 17, ">")
  end
end

local function draw()
  local t = T()
  frames = frames + 1
  R.begin()
  if state == "settings" then
    draw_settings()
  else
    R.backdrop(world and state == "play" and world.tick * 0.5 or frames * 0.3)
    if world and (state == "play" or state == "pause" or state == "countdown" or state == "over") then
      R.world(world, fx, frames)
      R.hud(world, best, t)
    end
    if state == "calibrate" then
      R.center(50, t.title, R.C.gold)
      local msg = t.cal_hold
      if tilt.cal_state == "moving" then msg = t.cal_moving end
      if not tilt.accel and now - state_t0 > NO_SAMPLE_US then msg = t.cal_wait end
      R.center(100, msg)
      if now - state_t0 > CAL_SKIP_US then R.center(170, t.cal_skip, R.C.dim) end
    elseif state == "title" then
      gfx.text(4, 4, "v" .. VERSION, R.C.dim)
      R.center(36, t.title, R.C.gold)
      R.center(56, t.subtitle, R.C.accent)
      R.center(76, ("%s %d"):format(t.best, best), R.C.dim)
      R.button("start", 100, 100, 120, 28, t.start, true)
      R.button("settings", 100, 136, 120, 24, t.settings)
      if not touch_mode() then R.button("recenter", 100, 166, 120, 24, t.recenter) end
      R.center(204, touch_mode() and t.hint_touch or t.hint_tilt, R.C.dim)
      if imu.missing then R.center(220, t.no_imu, R.C.warn) end
      if not touch_mode() then R.stick(280, 150, ux, uy, tilt_ok()) end
    elseif state == "countdown" then
      R.panel(80, 80, 160, 70)
      R.center(92, t.countdown_hold, R.C.white)
      R.center(118, tostring(math.max(1, math.ceil(countdown_us / 1000000))), R.C.gold)
      if not touch_mode() then R.stick(280, 200, ux, uy, tilt_ok()) end
    elseif state == "pause" then
      R.panel(60, 40, 200, 176)
      R.center(48, t.paused, R.C.gold)
      if pause_reason then R.center(64, pause_reason, R.C.warn) end
      R.button("resume", 90, 84, 140, 26, t.resume, true)
      if not touch_mode() then R.button("recenter", 90, 116, 140, 24, t.recenter) end
      R.button("settings", 90, 146, 140, 24, t.settings)
      R.button("title", 90, 176, 140, 24, t.quit)
      if not touch_mode() then R.stick(290, 200, ux, uy, tilt_ok()) end
    elseif state == "over" and result then
      R.panel(60, 50, 200, 150)
      R.center(60, t.game_over, R.C.warn)
      R.center(82, ("%s %d"):format(t.score, result.score), R.C.white)
      if result.best then R.center(98, t.new_best, R.C.gold)
      else R.center(98, ("%s %d"):format(t.best, best), R.C.dim) end
      R.center(116, ("%s %.0fs  %s %d  %s %d"):format(t.time, result.secs, t.caught,
               world.stats.barrier + world.stats.star, t.absorbed, world.stats.absorbed), R.C.dim)
      R.button("retry", 90, 138, 140, 26, t.retry, true)
      R.button("title", 90, 170, 140, 22, t.quit)
    end
  end
  if cfg.diag then R.diag(diag_lines()) end
  if toast and now < toast_until then
    local w = R.text_width(toast) + 16
    R.panel(160 - w // 2, 218, w, 18)
    R.center(221, toast, R.C.accent)
  end
  gfx.present()
end

-- actions -----------------------------------------------------------------------------------

local function apply_mode()
  if cfg.mode == "touch" then
    close_sensors()
  else
    imu.missing = nil
    tilt:set_mode(cfg.mode)
    open_sensors()
    if not tilt.neutral then
      need_center = true
      if not tilt.bias_ok then tilt:calibrate() end -- completes whenever the device is still
    end
  end
end

local function action(id)
  if not id then return end
  if id == "start" or id == "retry" then
    new_run()
  elseif id == "settings" then
    go("settings")
  elseif id == "recenter" then
    recenter()
  elseif id == "resume" then
    if tilt_ok() then
      pause_reason = nil
      countdown_us = COUNTDOWN_US
      go("countdown")
    else
      show(T().paused_sensor)
    end
  elseif id == "pause" then
    if state == "play" or state == "countdown" then pause(nil) end
  elseif id == "title" then
    world = nil
    go("title")
  elseif id == "back" then
    go(prev_state or "title")
  else
    local dir, key = id:match("^(%a+):([%w_]+)$")
    if key then
      Settings.step(cfg, key, dir == "inc" and 1 or -1)
      if key == "mode" then apply_mode() end
      save_settings()
    end
  end
end

-- events ------------------------------------------------------------------------------------

giii.on("tick", function(t_us)
  now = t_us
  frame_us = last_t and (t_us - last_t) or 0
  last_t = t_us
  read_sensors()
  if need_center and not touch_mode() and tilt:status(now) == "ok" then
    need_center = false
    recenter()
  end
  update_input(frame_us)
  local dt, n = frame_us * 1e-6, 0
  for i = 1, #fx do -- move the particles, dropping the spent ones in place
    local p = fx[i]
    fx[i] = nil
    p.x, p.y, p.life = p.x + p.vx * dt, p.y + p.vy * dt, p.life - dt
    if p.life > 0 then
      n = n + 1
      fx[n] = p
    end
  end

  if state == "calibrate" then
    if touch_mode() then
      go("title")
    elseif tilt.cal_state == "done" then
      tilt:recenter()
      show(T().cal_done)
      log("CALIBRATED bias=%.4f,%.4f,%.4f", tilt.bias[1], tilt.bias[2], tilt.bias[3])
      go("title")
    end
  elseif state == "countdown" then
    if not tilt_ok() then
      pause(T().paused_sensor)
    else
      countdown_us = countdown_us - frame_us
      if countdown_us <= 0 then
        acc_us = 0
        go("play")
      end
    end
  elseif state == "play" then
    if not tilt_ok() then
      log("PAUSE sensor %s", tilt:status(now))
      pause(T().paused_sensor)
    else
      step_world()
    end
  end
  draw()
end)

giii.on("input", function(ev)
  if ev.kind == "pointer" then
    if state == "play" and touch_mode() and ev.phase ~= "up" then
      if R.hit(ev.x, ev.y) == "pause" and ev.phase == "down" then
        pause(nil)
      else
        touch_target = touch_target or {}
        touch_target.x, touch_target.y = ev.x, ev.y
      end
      return
    end
    if ev.phase == "up" then
      touch_target = nil
      if state == "calibrate" and now - state_t0 > CAL_SKIP_US then
        tilt.cal = nil
        tilt.cal_state = "skipped"
        if not tilt:recenter() then
          -- nothing ever arrived: offer the touch alternative instead of a dead ship
          close_sensors()
          imu.missing = "no samples"
        end
        log("CALIBRATION skipped imu=%s", tostring(imu.missing))
        go("title")
        return
      end
      action(R.hit(ev.x, ev.y))
    end
  elseif ev.kind == "button" and ev.value == 1 then
    local b = ev.code
    if b == giii.input.START then
      if state == "play" or state == "countdown" then pause(nil)
      elseif state == "pause" then action("resume") end
    elseif b == giii.input.A then
      if state == "title" then action("start")
      elseif state == "over" then action("retry")
      elseif state == "pause" then action("resume") end
    elseif b == giii.input.B then
      if state == "settings" then action("back")
      elseif state == "pause" then action("title") end
    end
  end
end)

local function to_background()
  if state == "play" or state == "countdown" then pause(T().paused_bg) end
  close_sensors()
  last_t = nil
end

local function to_foreground()
  open_sensors()
  if state == "calibrate" then tilt:calibrate() end
  last_t = nil
end

giii.on("background", to_background)
giii.on("suspend", to_background)
giii.on("foreground", to_foreground)
giii.on("resume", to_foreground)
giii.on("stop", function() close_sensors() end)

log("BOOT best=%d mode=%s lang=%s", best, cfg.mode, cfg.lang)
open_sensors()
tilt:calibrate()
go("calibrate")
draw()
