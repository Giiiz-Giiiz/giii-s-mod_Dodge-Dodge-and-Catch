local Tilt = require("ddc.tilt")
local G = Tilt.G
local test, eq, near, ok = T.test, T.eq, T.near, T.ok

local function sample(t_us, x, y, z, q) return {t_us = t_us, x = x, y = y, z = z, quality = q or 0, missed = 0} end

-- Gravity reading for a device rolled by `roll` (right edge down, deg) and pitched by
-- `pitch` (bottom edge down, deg) from flat, face up.
local function up_for(roll, pitch)
  local r, p = math.rad(roll), math.rad(pitch)
  -- rotate up (0,0,1): right edge down -> up leans to -x; bottom edge down -> up leans to +y
  local x, y, z = -math.sin(r), 0, math.cos(r)
  y, z = y * math.cos(p) + z * math.sin(p), -y * math.sin(p) + z * math.cos(p)
  return x * G, y * G, z * G
end

-- Feeds accel and gyro at `hz` from t0 for `secs`; gyro(t) and accel(t) give vectors.
local function run(tilt, t0, secs, hz, accel, gyro)
  local step = 1000000 // hz
  local t = t0
  for _ = 1, math.floor(secs * hz) do
    t = t + step
    local gx, gy, gz = gyro(t)
    tilt:feed_gyro(sample(t, gx, gy, gz))
    local ax, ay, az = accel(t)
    tilt:feed_accel(sample(t, ax, ay, az))
  end
  return t
end

local function flat() return 0, 0, G end
local function still() return 0, 0, 0 end

test("tilt: still device stays centred and ok", function()
  local t = Tilt.new()
  local now = run(t, 0, 0.2, 100, flat, still)
  ok(t:recenter())
  now = run(t, now, 10, 100, flat, still)
  local x, y = t:relative()
  near(x, 0, 0.01, "x")
  near(y, 0, 0.01, "y")
  eq(t:status(now), "ok")
end)

test("tilt: signs - right edge down is +x, bottom edge down is +y", function()
  local t = Tilt.new({mode = "accel"})
  run(t, 0, 0.1, 100, flat, still)
  t:recenter()
  run(t, 100000, 0.1, 100, function() return up_for(15, 0) end, still)
  local x, y = t:relative()
  near(x, 15, 0.1, "roll")
  near(y, 0, 0.1, "pitch")
  run(t, 200000, 0.1, 100, function() return up_for(0, 12) end, still)
  x, y = t:relative()
  near(x, 0, 0.1, "roll")
  near(y, 12, 0.1, "pitch")
end)

test("tilt: gyro rotation matches the accelerometer convention", function()
  -- +y angular rate drops the right edge: gyro-only integration must agree with up_for().
  local t = Tilt.new({mode = "gyro"})
  local now = run(t, 0, 0.1, 100, flat, still)
  t:recenter()
  run(t, now, 0.5, 100, flat, function() return 0, 1.0, 0 end) -- 0.5 rad
  local x, y = t:relative()
  near(x, math.deg(0.5), 0.5, "roll from gyro")
  near(y, 0, 0.2, "pitch")
  -- +x rate lifts the top edge (bottom edge down)
  t = Tilt.new({mode = "gyro"})
  now = run(t, 0, 0.1, 100, flat, still)
  t:recenter()
  run(t, now, 0.3, 100, flat, function() return 1.0, 0, 0 end)
  x, y = t:relative()
  near(y, math.deg(0.3), 0.5, "pitch from gyro")
end)

test("tilt: same accel, different gyro -> fused attitude follows the gyro", function()
  local function ride(gyro)
    local t = Tilt.new({mode = "fused"})
    local now = run(t, 0, 0.3, 100, flat, still)
    t:recenter()
    run(t, now, 0.2, 100, flat, gyro)
    return (t:relative())
  end
  local quiet = ride(still)
  local turned = ride(function() return 0, 1.5, 0 end) -- 0.3 rad in 0.2 s
  near(quiet, 0, 0.01, "no gyro")
  ok(turned > 10, ("gyro must move the estimate, got %.2f deg"):format(turned))
end)

test("tilt: fused converges to gravity without gyro motion and rejects drift", function()
  local t = Tilt.new({mode = "fused"})
  local now = run(t, 0, 0.1, 100, flat, still)
  t:recenter()
  -- a constant gyro bias would spin gyro-only forever; fused stays bounded
  run(t, now, 20, 100, flat, function() return 0, 0.02, 0 end)
  local x = t:relative()
  ok(math.abs(x) < 1.0, ("bias drift bounded, got %.2f"):format(x))
  local g = Tilt.new({mode = "gyro"})
  now = run(g, 0, 0.1, 100, flat, still)
  g:recenter()
  run(g, now, 20, 100, flat, function() return 0, 0.02, 0 end)
  ok((g:relative()) > 20, "gyro-only drifts (diagnostic mode shows it)")
end)

test("tilt: fused tracks a held tilt", function()
  local t = Tilt.new({mode = "fused"})
  local now = run(t, 0, 0.1, 100, flat, still)
  t:recenter()
  run(t, now, 4, 100, function() return up_for(-20, 0) end, still)
  near((t:relative()), -20, 0.5, "converged")
end)

test("tilt: neutral grip is relative to how the player holds it", function()
  local t = Tilt.new({mode = "accel"})
  run(t, 0, 0.1, 100, function() return up_for(0, -40) end, still) -- reclined grip
  t:recenter()
  local x, y = t:relative()
  near(x, 0, 0.01) near(y, 0, 0.01)
  run(t, 100000, 0.1, 100, function() return up_for(0, -30) end, still)
  x, y = t:relative()
  near(y, 10, 0.2, "10 deg forward from the grip")
  near(x, 0, 0.2)
end)

test("tilt: stale, NaN, unreliable and gaps are reported", function()
  local t = Tilt.new()
  eq(t:status(0), "waiting")
  local now = run(t, 0, 0.2, 100, flat, still)
  eq(t:status(now), "ok")
  eq(t:status(now + 400000), "stale")
  t:feed_gyro(sample(now + 10000, 0 / 0, 0, 0))
  eq(t:status(now + 10000), "nan")
  t:reset()
  now = run(t, now, 0.2, 100, flat, still)
  t:feed_accel(sample(now + 10000, 0, 0, G, 2))
  eq(t:status(now + 10000), "quality")
  now = run(t, now + 10000, 0.1, 100, flat, still)
  eq(t:status(now), "ok", "a good sample clears the fault (the OS restarts failed sensors)")
  t:reset()
  now = run(t, now + 20000, 0.1, 100, flat, still)
  local up = {t.up[1], t.up[2], t.up[3]}
  t:feed_gyro(sample(now + 500000, 0, 5, 0)) -- 0.5 s gap must not integrate 2.5 rad
  near(t.up[1], up[1], 1e-9) near(t.up[3], up[3], 1e-9)
  ok(t.gaps >= 1)
end)

test("tilt: bias calibration needs stillness", function()
  local t = Tilt.new()
  t:calibrate()
  run(t, 0, 1.0, 100, flat, function() return 0.02, -0.01, 0.005 end)
  eq(t.cal_state, "done")
  near(t.bias[1], 0.02, 1e-6) near(t.bias[2], -0.01, 1e-6)
  -- moving device: never commits
  local m = Tilt.new()
  m:calibrate()
  run(m, 0, 2.0, 100, flat, function(tt) return 0, math.sin(tt / 50000) * 0.5, 0 end)
  ok(m.cal_state ~= "done" and not m.bias_ok, "no bias while moving")
end)

test("tilt: shape applies dead zone, curve and saturation", function()
  local cfg = {dead = 3, max = 20, curve = 1}
  eq(Tilt.shape(2, cfg), 0)
  eq(Tilt.shape(-3, cfg), 0)
  near(Tilt.shape(11.5, cfg), 0.5, 1e-9)
  near(Tilt.shape(-11.5, cfg), -0.5, 1e-9)
  eq(Tilt.shape(45, cfg), 1)
  eq(Tilt.shape(-45, cfg), -1)
  cfg.curve = 2
  near(Tilt.shape(11.5, cfg), 0.25, 1e-9)
end)
