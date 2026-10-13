-- Game rules: ship, meteors, items, barrier, score. Fixed 60 Hz tick, own PRNG, no giii.*
-- calls, so a seed plus the per-tick inputs reproduce a run exactly (docs/rules.md).
local M = {}

M.HZ = 60
M.FIELD = {x = 0, y = 18, w = 320, h = 222} -- below the HUD bar
M.SHIP_R = 7
M.SHIP_SPEED = 170 -- px/s at full deflection
M.BARRIER_TICKS = 8 * 60
M.BARRIER_MAX = 2
M.INVULN_TICKS = 60
M.LEVEL_TICKS = 15 * 60
M.MAX_LEVEL = 10
M.STAR_SCORE = 50
M.BARRIER_SCORE = 10

-- Item kinds. A new kind adds an entry here; nothing else needs to know about it.
M.ITEMS = {
  barrier = {
    r = 7, weight = 35,
    catch = function(w)
      local s = w.shield
      s.charges = math.min(s.charges + 1, M.BARRIER_MAX)
      s.timer = M.BARRIER_TICKS
      w.score = w.score + M.BARRIER_SCORE
    end,
  },
  star = {
    r = 7, weight = 65,
    catch = function(w) w.score = w.score + M.STAR_SCORE end,
  },
}
M.ITEM_ORDER = {"barrier", "star"} -- deterministic weighted pick

-- xorshift32: the same sequence on every Lua build (math.random is not portable).
local function rng(seed)
  local s = seed & 0xFFFFFFFF
  if s == 0 then s = 0x9E3779B9 end
  return function()
    s = s ~ ((s << 13) & 0xFFFFFFFF)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & 0xFFFFFFFF)
    return s
  end
end

function M.new(seed)
  local w = setmetatable({}, {__index = M})
  w.seed = seed
  w.next = rng(seed)
  w.tick = 0
  w.score = 0
  w.level = 1
  local f = M.FIELD
  w.ship = {x = f.x + f.w / 2, y = f.y + f.h - 24, r = M.SHIP_R}
  w.meteors = {}
  w.items = {}
  w.shield = {charges = 0, timer = 0}
  w.invuln = 0
  w.over = false
  w.spawn_in = 60 -- first meteor after one second
  w.item_in = 3 * 60
  w.wall_in = 5 * 60 -- counts down only from level 6
  w.events = {}
  w.stats = {barrier = 0, star = 0, absorbed = 0, expired = 0, meteors = 0}
  return w
end

-- Uniform float in [a, b).
function M:rand(a, b) return a + (b - a) * (self.next() / 4294967296) end
function M:randi(n) return self.next() % n end

local function emit(w, kind, a, b)
  w.events[#w.events + 1] = {tick = w.tick, kind = kind, a = a, b = b}
end

M.RADII = {6, 9, 13} -- meteor sizes; render.lua draws one sprite set per size
local RADII = M.RADII

local function meteor_speed(w) return 70 + w.level * 14 end

local function add_meteor(w, x, r, vx, vy)
  w.meteors[#w.meteors + 1] = {x = x, y = M.FIELD.y - r, r = r, vx = vx, vy = vy,
                               spin = w:randi(4)}
  w.stats.meteors = w.stats.meteors + 1
end

local function spawn_meteors(w)
  local f = M.FIELD
  local base = meteor_speed(w)
  local roll = w:randi(100)
  if w.level >= 3 and roll < 25 then
    -- pair, forcing a choice of side
    local gap = w:rand(70, 120)
    local x = w:rand(f.x + 20, f.x + f.w - 20 - gap)
    local r = RADII[1 + w:randi(2)]
    add_meteor(w, x, r, 0, base * w:rand(0.9, 1.1))
    add_meteor(w, x + gap, r, 0, base * w:rand(0.9, 1.1))
  elseif w.level >= 4 and roll < 45 then
    -- diagonal
    local r = RADII[1 + w:randi(3)]
    local x = w:rand(f.x + r, f.x + f.w - r)
    local vx = (x < f.x + f.w / 2 and 1 or -1) * base * w:rand(0.25, 0.5)
    add_meteor(w, x, r, vx, base * w:rand(0.8, 1.0))
  else
    local r = RADII[1 + w:randi(3)]
    add_meteor(w, w:rand(f.x + r, f.x + f.w - r), r, 0, base * w:rand(0.7, 1.3))
  end
end

local function spawn_wall(w)
  -- a row of small meteors with one ship-sized gap
  local f = M.FIELD
  local r = 9
  local gap_w = 56
  local gap_x = w:rand(f.x + 10, f.x + f.w - 10 - gap_w)
  local vy = meteor_speed(w) * 0.8
  local x = f.x + r
  while x < f.x + f.w do
    if x + r < gap_x or x - r > gap_x + gap_w then add_meteor(w, x, r, 0, vy) end
    x = x + 2 * r + 4
  end
  emit(w, "wall")
end

local function spawn_item(w)
  local total = 0
  for _, k in ipairs(M.ITEM_ORDER) do total = total + M.ITEMS[k].weight end
  local pick = w:randi(total)
  local kind
  for _, k in ipairs(M.ITEM_ORDER) do
    pick = pick - M.ITEMS[k].weight
    if pick < 0 then kind = k break end
  end
  local f = M.FIELD
  local r = M.ITEMS[kind].r
  w.items[#w.items + 1] = {kind = kind, x = w:rand(f.x + 16, f.x + f.w - 16), y = f.y - r,
                           r = r, vx = 0, vy = 60 + w.level * 4}
end

-- Do two circles moving linearly during the tick come within reach of each other?
-- Using the relative motion makes fast objects unable to pass through the ship.
local function swept(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1, reach)
  local px, py = ax0 - bx0, ay0 - by0
  local dx, dy = (ax1 - bx1) - px, (ay1 - by1) - py
  local dd = dx * dx + dy * dy
  local t = 0
  if dd > 0 then
    t = -(px * dx + py * dy) / dd
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local cx, cy = px + dx * t, py + dy * t
  return cx * cx + cy * cy <= reach * reach
end
M.swept = swept

-- Moves every object and drops the ones that left the field, compacting in place.
local function move_all(list, dt, bottom)
  local n = 0
  local left, right = M.FIELD.x - 40, M.FIELD.x + M.FIELD.w + 40
  for i = 1, #list do
    local o = list[i]
    list[i] = nil
    o.px, o.py = o.x, o.y
    o.x, o.y = o.x + o.vx * dt, o.y + o.vy * dt
    if o.y - o.r <= bottom and o.x + o.r >= left and o.x - o.r <= right then
      n = n + 1
      list[n] = o
    end
  end
end

-- One fixed tick. ux, uy in [-1, 1]: ship velocity as a fraction of SHIP_SPEED.
-- Order inside a tick (docs/rules.md): ship, objects, catches, hits, timers, spawns.
function M:step(ux, uy)
  if self.over then return end
  local dt = 1 / M.HZ
  local f = M.FIELD
  self.tick = self.tick + 1
  self.level = math.min(M.MAX_LEVEL, 1 + self.tick // M.LEVEL_TICKS)

  -- 1. ship
  local s = self.ship
  ux = math.max(-1, math.min(1, ux or 0))
  uy = math.max(-1, math.min(1, uy or 0))
  s.px, s.py = s.x, s.y
  s.x = math.max(f.x + s.r, math.min(f.x + f.w - s.r, s.x + ux * M.SHIP_SPEED * dt))
  s.y = math.max(f.y + s.r, math.min(f.y + f.h - s.r, s.y + uy * M.SHIP_SPEED * dt))

  -- 2. objects
  local bottom = f.y + f.h
  move_all(self.meteors, dt, bottom)
  move_all(self.items, dt, bottom)

  -- 3. catches come first: grabbing a barrier in the same tick as a hit saves you
  local items = self.items
  for i = #items, 1, -1 do -- removal from the back keeps the earlier indices valid
    local it = items[i]
    if swept(s.px, s.py, s.x, s.y, it.px, it.py, it.x, it.y, s.r + it.r) then
      table.remove(items, i)
      M.ITEMS[it.kind].catch(self)
      self.stats[it.kind] = (self.stats[it.kind] or 0) + 1
      emit(self, "catch", it.kind, it.x)
    end
  end

  -- 4. at most one hit per tick; the barrier's invulnerability covers the rest
  if self.invuln == 0 then
    for i, m in ipairs(self.meteors) do
      if swept(s.px, s.py, s.x, s.y, m.px, m.py, m.x, m.y, s.r + m.r * 0.85) then
        if self.shield.charges > 0 then
          self.shield.charges = self.shield.charges - 1
          if self.shield.charges == 0 then self.shield.timer = 0 end
          self.invuln = M.INVULN_TICKS
          self.stats.absorbed = self.stats.absorbed + 1
          table.remove(self.meteors, i)
          emit(self, "absorb", m.x, m.y)
        else
          self.over = true
          emit(self, "hit", m.x, m.y)
          return
        end
        break
      end
    end
  end

  -- 5. timers and score
  if self.invuln > 0 then self.invuln = self.invuln - 1 end
  if self.shield.timer > 0 then
    self.shield.timer = self.shield.timer - 1
    if self.shield.timer == 0 and self.shield.charges > 0 then
      self.shield.charges = 0
      self.stats.expired = self.stats.expired + 1
      emit(self, "expire")
    end
  end
  if self.tick % 6 == 0 then self.score = self.score + 1 end

  -- 6. spawns (they appear above the field and move from the next tick)
  self.spawn_in = self.spawn_in - 1
  if self.spawn_in <= 0 then
    spawn_meteors(self)
    self.spawn_in = math.max(14, 48 - self.level * 4)
  end
  self.item_in = self.item_in - 1
  if self.item_in <= 0 then
    spawn_item(self)
    self.item_in = 4 * 60 + self:randi(3 * 60)
  end
  if self.level >= 6 then
    self.wall_in = self.wall_in - 1
    if self.wall_in <= 0 then
      spawn_wall(self)
      self.wall_in = 10 * 60
    end
  end
end

-- Hands each event since the last call to fn(e) and forgets it, so a long run does not
-- keep every event it ever had.
function M:drain_events(fn)
  local ev = self.events
  for i = 1, #ev do
    fn(ev[i])
    ev[i] = nil
  end
end

-- Compact state digest for replay comparison.
function M:digest()
  local h = 2166136261
  local function mix(v)
    v = math.floor(v * 256 + 0.5)
    h = ((h ~ (v & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
  end
  mix(self.tick) mix(self.score) mix(self.ship.x) mix(self.ship.y)
  mix(self.shield.charges) mix(self.shield.timer) mix(self.invuln)
  for _, m in ipairs(self.meteors) do mix(m.x) mix(m.y) mix(m.r) end
  for _, it in ipairs(self.items) do mix(it.x) mix(it.y) end
  return string.format("%08x", h)
end

return M
