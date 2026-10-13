-- Drawing: playfield, HUD, menus and the diagnostics overlay. Holds sprites and the
-- touch targets of the frame being drawn; game rules live in world.lua.
local art = require("ddc.art")
local World = require("ddc.world")

local M = {}

local gfx
local C = {}
local spr = {}
local buttons, nbuttons = {}, 0 -- touch targets of this frame; the tables are reused
local stars = {}
local RING = {} -- unit circle, 20 segments
for i = 0, 20 do RING[i] = {math.cos(i / 20 * 2 * math.pi), math.sin(i / 20 * 2 * math.pi)} end

local floor = math.floor

function M.init(g)
  gfx = g
  local rgb = gfx.rgb
  C.bg = rgb(6, 8, 20)
  C.hud = rgb(16, 20, 40)
  C.white = 0xFFFF
  C.dim = rgb(140, 150, 180)
  C.accent = rgb(120, 230, 255)
  C.warn = rgb(255, 120, 80)
  C.gold = rgb(255, 210, 80)
  C.button = rgb(36, 46, 86)
  C.button_edge = rgb(110, 130, 200)
  C.panel = rgb(12, 14, 30)
  C.shield = rgb(120, 240, 255)
  C.shield_dim = rgb(50, 110, 140)
  C.star1 = rgb(90, 90, 120)
  C.star2 = rgb(200, 200, 230)
  local function make(w, h, px)
    local s = gfx.sprite(w, h, px)
    return s and {id = s, w = w, h = h}
  end
  spr.ship = make(art.ship())
  spr.barrier = make(art.barrier())
  spr.star = make(art.star())
  spr.meteor = {}
  for _, r in ipairs(World.RADII) do
    spr.meteor[r] = {}
    for v = 1, 3 do spr.meteor[r][v] = make(art.meteor(r, v * 1.7)) end
  end
  collectgarbage("collect") -- drop the generator garbage before the game allocates
  for i = 1, 48 do
    stars[i] = {x = math.random(0, 319), y = math.random(18, 239), v = (i % 3) + 1}
  end
end

-- Width of a string in the built-in 12 px font: ASCII 6 px, everything else 12 px.
function M.text_width(s)
  local n = 0
  for _, c in utf8.codes(s) do n = n + (c < 128 and 6 or 12) end
  return n
end

function M.center(y, s, c)
  local i = 0
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    gfx.text(floor(160 - M.text_width(line) / 2), floor(y + i * 14), line, c or C.white)
    i = i + 1
  end
end

function M.begin()
  nbuttons = 0
end

-- An invisible touch target.
function M.zone(id, x, y, w, h)
  nbuttons = nbuttons + 1
  local b = buttons[nbuttons]
  if not b then
    b = {}
    buttons[nbuttons] = b
  end
  b.id, b.x, b.y, b.w, b.h = id, x, y, w, h
end

function M.button(id, x, y, w, h, label, hot)
  gfx.fill(x, y, w, h, hot and C.button_edge or C.button)
  gfx.rect(x, y, w, h, C.button_edge)
  gfx.text(floor(x + (w - M.text_width(label)) / 2), floor(y + (h - 12) / 2), label, C.white)
  M.zone(id, x, y, w, h)
end

-- Which button (if any) is under a tap.
function M.hit(x, y)
  for i = nbuttons, 1, -1 do
    local b = buttons[i]
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return b.id end
  end
end

function M.backdrop(scroll)
  gfx.clear(C.bg)
  for _, s in ipairs(stars) do
    local y = 18 + (s.y - 18 + scroll * s.v) % 222
    gfx.fill(s.x, floor(y), s.v == 3 and 2 or 1, s.v == 3 and 2 or 1, s.v == 1 and C.star1 or C.star2)
  end
end

local function blit(sp, x, y)
  if sp then gfx.blit(sp.id, floor(x - sp.w / 2), floor(y - sp.h / 2), 0, 0, sp.w, sp.h, art.KEY) end
end

local function circle(x, y, r, c)
  local px, py = floor(x + r), floor(y)
  for i = 1, 20 do
    local nx, ny = floor(x + r * RING[i][1]), floor(y + r * RING[i][2])
    gfx.line(px, py, nx, ny, c)
    px, py = nx, ny
  end
end

function M.world(w, fx, tick_count)
  for _, it in ipairs(w.items) do blit(spr[it.kind], it.x, it.y) end
  for _, m in ipairs(w.meteors) do
    local set = spr.meteor[m.r]
    blit(set and set[m.spin % 3 + 1], m.x, m.y)
  end
  local s = w.ship
  local blink = w.invuln > 0 and (w.invuln // 4) % 2 == 0
  if not w.over and not blink then blit(spr.ship, s.x, s.y + 1) end
  if w.shield.charges > 0 then
    local fading = w.shield.timer < 120 and (tick_count // 6) % 2 == 0
    local c = fading and C.shield_dim or C.shield
    circle(s.x, s.y, 13, c)
    if w.shield.charges > 1 then circle(s.x, s.y, 15, c) end
  end
  for _, p in ipairs(fx) do gfx.fill(floor(p.x), floor(p.y), 2, 2, p.c) end
end

function M.hud(w, best, t)
  gfx.fill(0, 0, 320, 18, C.hud)
  gfx.text(4, 3, ("%s %d"):format(t.score, w.score), C.white)
  gfx.text(104, 3, ("%s %d"):format(t.best, math.max(best, w.score)), C.dim)
  gfx.text(184, 3, ("%s%d"):format(t.level, w.level), C.gold)
  if w.shield.charges > 0 then
    local frac = w.shield.timer / World.BARRIER_TICKS
    gfx.rect(218, 5, 42, 8, C.shield)
    gfx.fill(219, 6, floor(40 * frac), 6, C.shield)
    gfx.text(208, 3, tostring(w.shield.charges), C.shield)
  end
  -- pause button
  gfx.fill(290, 1, 28, 16, C.button)
  gfx.fill(299, 4, 3, 10, C.white)
  gfx.fill(305, 4, 3, 10, C.white)
  M.zone("pause", 270, 0, 50, 30)
end

function M.panel(x, y, w, h)
  gfx.fill(x, y, w, h, C.panel)
  gfx.rect(x, y, w, h, C.button_edge)
end

-- Tilt indicator: where the logical input points, inside a box.
function M.stick(x, y, ux, uy, ok)
  gfx.rect(x - 20, y - 20, 40, 40, C.dim)
  gfx.line(x - 20, y, x + 19, y, C.star1)
  gfx.line(x, y - 20, x, y + 19, C.star1)
  gfx.fill(floor(x + ux * 17) - 3, floor(y + uy * 17) - 3, 6, 6, ok and C.accent or C.warn)
end

function M.diag(lines)
  local h = #lines * 13 + 4
  local y0 = 20 -- below the HUD: the ship lives at the bottom
  gfx.fill(0, y0, 230, h, C.panel)
  for i, l in ipairs(lines) do gfx.text(3, y0 + 2 + (i - 1) * 13, l, C.accent) end
end

M.C = C
return M
