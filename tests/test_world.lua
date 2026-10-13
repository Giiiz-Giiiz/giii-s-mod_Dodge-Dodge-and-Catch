local World = require("ddc.world")
local test, eq, near, ok = T.test, T.eq, T.near, T.ok

-- A world with spawning switched off, for placing objects by hand.
local function quiet()
  local w = World.new(1)
  w.spawn_in, w.item_in, w.wall_in = math.huge, math.huge, math.huge
  return w
end

local function meteor(w, dx, dy, r, vy)
  local m = {x = w.ship.x + dx, y = w.ship.y + dy, r = r or 6, vx = 0, vy = vy or 0, spin = 0}
  w.meteors[#w.meteors + 1] = m
  return m
end

local function item(w, kind, dx, dy)
  local it = {kind = kind, x = w.ship.x + dx, y = w.ship.y + dy, r = 7, vx = 0, vy = 0}
  w.items[#w.items + 1] = it
  return it
end

local function kinds(w)
  local out = {}
  for _, e in ipairs(w.events) do out[#out + 1] = e.kind end
  return table.concat(out, ",")
end

-- deterministic pseudo input
local function input(i) return math.sin(i / 37), math.cos(i / 53) * 0.6 end

test("world: same seed and inputs reproduce the run", function()
  local a, b = World.new(42), World.new(42)
  for i = 1, 3000 do
    local ux, uy = input(i)
    a:step(ux, uy)
    b:step(ux, uy)
  end
  eq(a:digest(), b:digest())
  eq(a.over, b.over)
  local c = World.new(43)
  for i = 1, 3000 do c:step(input(i)) end
  ok(c:digest() ~= a:digest(), "different seed differs")
end)

test("world: hit without barrier ends the run", function()
  local w = quiet()
  meteor(w, 0, 0)
  w:step(0, 0)
  ok(w.over)
  eq(kinds(w), "hit")
  local score = w.score
  w:step(0, 0)
  eq(w.score, score, "no steps after game over")
end)

test("world: barrier catch, absorb, invulnerability", function()
  local w = quiet()
  item(w, "barrier", 0, 0)
  w:step(0, 0)
  eq(w.shield.charges, 1)
  eq(w.shield.timer, World.BARRIER_TICKS - 1)
  eq(w.score, World.BARRIER_SCORE)
  meteor(w, 0, 0)
  w:step(0, 0)
  ok(not w.over, "absorbed")
  eq(w.shield.charges, 0)
  eq(w.shield.timer, 0)
  eq(w.invuln, World.INVULN_TICKS - 1)
  eq(#w.meteors, 0, "absorbed meteor removed")
  meteor(w, 0, 0)
  w:step(0, 0)
  ok(not w.over, "invulnerable right after absorbing")
  eq(kinds(w), "catch,absorb")
end)

test("world: barrier expires", function()
  local w = quiet()
  item(w, "barrier", 0, 0)
  for _ = 1, World.BARRIER_TICKS do w:step(0, 0) end
  eq(w.shield.charges, 0)
  eq(w.stats.expired, 1)
  eq(kinds(w), "catch,expire")
end)

test("world: second barrier refreshes the timer and stacks to the cap", function()
  local w = quiet()
  for i = 1, 3 do
    item(w, "barrier", 0, 0)
    for _ = 1, 100 do w:step(0, 0) end
  end
  eq(w.shield.charges, World.BARRIER_MAX)
  eq(w.shield.timer, World.BARRIER_TICKS - 100)
end)

test("world: catch is processed before the hit in the same tick", function()
  local w = quiet()
  item(w, "barrier", 0, 0)
  meteor(w, 0, 0)
  w:step(0, 0)
  ok(not w.over, "caught barrier saves the ship")
  eq(kinds(w), "catch,absorb")
end)

test("world: two meteors in one tick cost one charge", function()
  local w = quiet()
  w.shield.charges, w.shield.timer = 1, 100
  meteor(w, -3, 0)
  meteor(w, 3, 0)
  w:step(0, 0)
  ok(not w.over)
  eq(w.stats.absorbed, 1)
  eq(#w.meteors, 1)
  for _ = 1, World.INVULN_TICKS - 2 do w:step(0, 0) end
  ok(not w.over, "still covered")
end)

test("world: fast meteor cannot tunnel through the ship", function()
  local w = quiet()
  -- 3000 px/s: 50 px per tick, starting just above and ending well below the ship
  meteor(w, 0, -25, 6, 3000)
  w:step(0, 0)
  ok(w.over, "swept collision catches the pass")
  ok(World.swept(0, 0, 0, 0, 0, -30, 0, 30, 5))
  ok(not World.swept(0, 0, 0, 0, 20, -30, 20, 30, 5))
end)

test("world: star scores and items do not hurt", function()
  local w = quiet()
  item(w, "star", 0, 0)
  w:step(0, 0)
  eq(w.score, World.STAR_SCORE)
  ok(not w.over)
end)

test("world: ship stays inside the field", function()
  local w = quiet()
  for _ = 1, 600 do w:step(1, 1) end
  local f = World.FIELD
  eq(w.ship.x, f.x + f.w - w.ship.r)
  eq(w.ship.y, f.y + f.h - w.ship.r)
  for _ = 1, 600 do w:step(-1, -1) end
  eq(w.ship.x, f.x + w.ship.r)
  eq(w.ship.y, f.y + w.ship.r)
end)

test("world: difficulty rises and meteors arrive", function()
  local w = World.new(7)
  w.invuln = math.huge -- survive to watch the spawner
  for _ = 1, World.LEVEL_TICKS * 6 + 10 * 60 do w:step(0, 0) end
  eq(w.level, 7)
  ok(w.stats.meteors > 100, "meteors spawned: " .. w.stats.meteors)
  local walls = 0
  for _, e in ipairs(w.events) do if e.kind == "wall" then walls = walls + 1 end end
  ok(walls >= 1, "wall pattern at level 6+")
end)

test("world: drained events are handed over once and not kept", function()
  local w = quiet()
  item(w, "star", 0, 0)
  w:step(0, 0)
  local seen = {}
  w:drain_events(function(e) seen[#seen + 1] = e.kind .. ":" .. tostring(e.a) end)
  eq(table.concat(seen, ","), "catch:star")
  eq(#w.events, 0)
  w:drain_events(function() error("nothing new") end)
  item(w, "barrier", 0, 0)
  w:step(0, 0)
  w:drain_events(function(e) seen[#seen + 1] = e.kind .. ":" .. tostring(e.a) end)
  eq(table.concat(seen, ","), "catch:star,catch:barrier")
end)
