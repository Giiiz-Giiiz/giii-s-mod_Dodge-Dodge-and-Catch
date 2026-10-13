-- Tilt input pipeline (#2): timestamped gyro/accel -> gyro bias -> 6-axis attitude ->
-- tilt relative to the player's neutral grip -> logical 2-axis input in [-1, 1].
--
-- The attitude is the "up" direction in the screen frame (what a resting accelerometer
-- reads, normalised). Gyro samples rotate it (dg/dt = -w x g), accelerometer samples pull
-- it back towards gravity (complementary filter). Yaw is never needed, so the
-- magnetometer is not used and the CoreS3 magnet cannot disturb steering.
--
-- Pure Lua, no giii.* calls: the same module runs on the device, in the PC simulator and
-- in the host unit tests.
local M = {}

M.G = 9.80665
M.MODES = {"fused", "gyro", "accel"} -- touch is handled outside this module

local STALE_US = 300000 -- newest sample older than this: the sensor stopped
local GAP_US = 100000 -- gyro interval longer than this is not integrated
local CAL_US = 600000 -- still time needed to accept a gyro bias
local CAL_SPREAD = 0.06 -- rad/s: max deviation from the mean while "still"
local CAL_MAX_BIAS = 0.35 -- rad/s: a larger mean is motion, not bias
local QUALITY_UNRELIABLE = 2

local sqrt, atan, abs, exp, deg = math.sqrt, math.atan, math.abs, math.exp, math.deg

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end

local function norm3(x, y, z)
  local n = sqrt(x * x + y * y + z * z)
  if n < 1e-9 then return nil end
  return x / n, y / n, z / n, n
end

-- Rotation taking unit vector a onto +z (Rodrigues). Returns a function applying it.
local function align_to_z(ax, ay, az)
  -- axis k = a x z = (ay, -ax, 0), cos = az
  local kx, ky = ay, -ax
  local s = sqrt(kx * kx + ky * ky)
  local c = az
  if s < 1e-9 then
    if c > 0 then return function(x, y, z) return x, y, z end end
    return function(x, y, z) return x, -y, -z end -- 180 deg about x
  end
  kx, ky = kx / s, ky / s
  local t = 1 - c
  return function(x, y, z)
    -- v' = v c + (k x v) s + k (k.v) t, with k = (kx, ky, 0)
    local kdv = kx * x + ky * y
    return x * c + (ky * z) * s + kx * kdv * t,
           y * c + (-kx * z) * s + ky * kdv * t,
           z * c + (kx * y - ky * x) * s
  end
end

function M.new(opts)
  local t = setmetatable({}, {__index = M})
  t.mode = opts and opts.mode or "fused"
  t.tau = opts and opts.tau or 0.5 -- s, accel correction time constant (fused)
  t.bias = {0, 0, 0}
  t.bias_ok = false
  t.neutral = nil -- rotation to the neutral frame
  t.neutral_up = nil
  t:reset()
  return t
end

-- Forget the attitude (resume, sensor restart). Bias and neutral grip are kept.
function M:reset()
  self.up = nil -- {x, y, z}
  self.gyro_t, self.accel_t = nil, nil
  self.gyro, self.accel = nil, nil -- last raw samples
  self.anorm = nil
  self.fault = {} -- per sensor; cleared by the next good sample
  self.gaps = 0
  self.cal = nil
end

function M:set_mode(mode)
  if mode ~= self.mode then
    self.mode = mode
    self.up = nil -- re-seed from the accelerometer
  end
end

local function bad(s)
  return not (finite(s.x) and finite(s.y) and finite(s.z) and finite(s.t_us))
end

-- Starts collecting a gyro bias; succeeds after CAL_US of stillness.
function M:calibrate()
  self.cal = {n = 0, t0 = nil, sx = 0, sy = 0, sz = 0, minx = 1e9, maxx = -1e9,
              miny = 1e9, maxy = -1e9, minz = 1e9, maxz = -1e9}
  self.cal_state = "collecting"
end

local function cal_add(self, s)
  local c = self.cal
  local a = self.anorm
  local moving = a and abs(a - M.G) > 1.5
  if not c.t0 then c.t0 = s.t_us end
  c.n = c.n + 1
  c.sx, c.sy, c.sz = c.sx + s.x, c.sy + s.y, c.sz + s.z
  c.minx, c.maxx = math.min(c.minx, s.x), math.max(c.maxx, s.x)
  c.miny, c.maxy = math.min(c.miny, s.y), math.max(c.maxy, s.y)
  c.minz, c.maxz = math.min(c.minz, s.z), math.max(c.maxz, s.z)
  local spread = math.max(c.maxx - c.minx, c.maxy - c.miny, c.maxz - c.minz)
  if moving or spread > 2 * CAL_SPREAD then
    self:calibrate() -- moved: start over, never commit a bias measured in motion
    self.cal_state = "moving"
    return
  end
  if s.t_us - c.t0 >= CAL_US and c.n >= 8 then
    local bx, by, bz = c.sx / c.n, c.sy / c.n, c.sz / c.n
    if sqrt(bx * bx + by * by + bz * bz) <= CAL_MAX_BIAS then
      self.bias = {bx, by, bz}
      self.bias_ok = true
      self.cal = nil
      self.cal_state = "done"
      return
    end
    self:calibrate()
    self.cal_state = "moving"
  end
end

function M:feed_gyro(s)
  if not s or s.t_us == self.gyro_t then return false end
  if bad(s) then
    self.fault.gyro = "nan"
    return false
  end
  if s.quality and s.quality >= QUALITY_UNRELIABLE then
    self.fault.gyro = "quality"
    self.gyro_t = s.t_us
    return false
  end
  self.fault.gyro = nil
  local prev = self.gyro_t
  self.gyro_t = s.t_us
  self.gyro = s
  if self.cal then cal_add(self, s) end
  if prev == nil or not self.up or self.mode == "accel" then return true end
  local dt_us = s.t_us - prev
  if dt_us <= 0 or dt_us > GAP_US then
    self.gaps = self.gaps + 1 -- not integrated: the attitude waits for the accelerometer
    return true
  end
  local dt = dt_us * 1e-6
  -- The service delivers only the newest sample, so the rate is held over the interval.
  local wx, wy, wz = s.x - self.bias[1], s.y - self.bias[2], s.z - self.bias[3]
  local g = self.up
  -- dg = -(w x g) dt
  local cx = wy * g[3] - wz * g[2]
  local cy = wz * g[1] - wx * g[3]
  local cz = wx * g[2] - wy * g[1]
  local x, y, z = norm3(g[1] - cx * dt, g[2] - cy * dt, g[3] - cz * dt)
  if x then g[1], g[2], g[3] = x, y, z end -- in place: no garbage per sample
  return true
end

function M:feed_accel(s)
  if not s or s.t_us == self.accel_t then return false end
  if bad(s) then
    self.fault.accel = "nan"
    return false
  end
  if s.quality and s.quality >= QUALITY_UNRELIABLE then
    self.fault.accel = "quality"
    self.accel_t = s.t_us
    return false
  end
  self.fault.accel = nil
  local prev = self.accel_t
  self.accel_t = s.t_us
  self.accel = s
  local x, y, z, n = norm3(s.x, s.y, s.z)
  if not x then return true end
  self.anorm = n
  if not self.up then
    self.up = {x, y, z}
    return true
  end
  if self.mode == "accel" then
    self.up[1], self.up[2], self.up[3] = x, y, z
    return true
  end
  if self.mode == "gyro" or prev == nil then return true end
  local dt = (s.t_us - prev) * 1e-6
  if dt <= 0 then return true end
  if dt > GAP_US * 1e-6 then dt = GAP_US * 1e-6 end
  -- Trust gravity less while the device is being shaken.
  local w = 1 - abs(n - M.G) / 3
  if w <= 0 then return true end
  local k = (1 - exp(-dt / self.tau)) * w
  local g = self.up
  local ux, uy, uz = norm3(g[1] + (x - g[1]) * k, g[2] + (y - g[2]) * k, g[3] + (z - g[3]) * k)
  if ux then g[1], g[2], g[3] = ux, uy, uz end
  return true
end

-- "ok", or why the tilt cannot be trusted right now.
function M:status(now_us)
  local f = self.fault.accel or (self.mode ~= "accel" and self.fault.gyro)
  if f then return f end
  if not self.up or not self.accel_t then return "waiting" end
  if self.mode ~= "accel" and not self.gyro_t then return "waiting" end
  local newest = self.accel_t
  if self.mode ~= "accel" then newest = math.min(newest, self.gyro_t) end
  if now_us - newest > STALE_US then return "stale" end
  return "ok"
end

function M:age_ms(now_us)
  local g = self.gyro_t and (now_us - self.gyro_t) / 1000
  local a = self.accel_t and (now_us - self.accel_t) / 1000
  return g, a
end

function M:recenter()
  if not self.up then return false end
  local g = self.up
  self.neutral_up = {g[1], g[2], g[3]}
  self.neutral = align_to_z(g[1], g[2], g[3])
  return true
end

-- Tilt from the neutral grip in degrees: +x = right edge down, +y = bottom edge down.
function M:relative()
  if not self.up then return 0, 0 end
  local g = self.up
  local x, y, z = g[1], g[2], g[3]
  if self.neutral then x, y, z = self.neutral(x, y, z) end
  return -deg(atan(x, z)), deg(atan(y, z))
end

-- Absolute roll/pitch of the up vector, for diagnostics.
function M:absolute()
  if not self.up then return 0, 0 end
  local g = self.up
  return -deg(atan(g[1], g[3])), deg(atan(g[2], g[3]))
end

-- Tilt angle -> logical axis value.
-- cfg: dead (deg), max (deg at full deflection), curve (>= 1)
function M.shape(angle, cfg)
  local a = abs(angle) - cfg.dead
  if a <= 0 then return 0 end
  local span = cfg.max - cfg.dead
  if span <= 0 then return angle > 0 and 1 or -1 end
  local u = a / span
  if u > 1 then u = 1 end
  u = u ^ cfg.curve
  return angle > 0 and u or -u
end

return M
