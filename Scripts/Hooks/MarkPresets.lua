--[[
  MarkPresets -- preset text buttons attached under the F10 map mark dialog.

  Install:  Saved Games\DCS\Scripts\Hooks\MarkPresets.lua
  Config:   Saved Games\DCS\Config\MarkPresetsConfig.lua   (hand-edited, never written)
  Log:      Saved Games\DCS\Logs\MarkPresets.log

  Use:
    1. Put the config in place and set `mission` or `pattern` to match your mission.
    2. Start DCS and load that mission.
    3. Open the F10 map and click a mark, or place a new one. The preset panel
       appears under the dialog; click a preset to write it into the mark.

  Touches:
    Scripts\UI\F10View\MarkPanel.dlg      -- eMarkLable, sMarkId, bodyPanel,
                                             headePanel; skin colours
    dxgui                                 -- raw calls on DCS-owned widgets
    dxgui\bind\{Widget,Window,Panel}.lua  -- wrapper classes for our own widgets
    Scripts\tools.lua                     -- Tools.safeDoFile for config

  Depends on nothing outside the DCS install.

  Presets are gated on where you are playing: each profile matches a mission, a server,
  or both, and nothing runs unless you are in a slot. Outside a matching profile the
  hook is a no-op costing one boolean test per frame.

  Rules a future editor must not undo. Each is enforced, and measured, where it applies.

    * The panel is a separate top-level Window, never inserted into the dialog's tree.
    * A mark dialog's handles are held across frames. No other DCS-owned widget may be.
    * The first held-handle read of a session goes through the marker protocol, and a
      marker found at startup disables the hook.
    * Position is event-driven. The only clock is a slow check for the dialog having
      been hidden, which nothing announces.
    * The dialog's own behaviour is never changed. Nothing hides, moves, resizes or
      closes one uninvited, and nothing sends a mark uninvited.
    * The edit box is focused BEFORE each write, never after.
    * Widgets are built once per mission and destroyed at onSimulationStop.
--]]

-- Checked before anything registers: off costs one load and nothing else.
local ENABLED = true

-- Lua 5.1 allows 200 locals per function and the main chunk is one, so every top-level
-- `local` here counts against that. Overrunning it is a load-time error in dcs.log.
local VERSION = "6.1.0"

-- No package.path mutation: the incoming path already carries .\Scripts\?.lua and
-- .\Scripts\UI\?.lua, so require("tools") resolves. It is a global shared with DCS's
-- own UI code and every other hook.

local lfs    = require("lfs")
local dxgui  = require("dxgui")
local Tools  = require("tools")

local Widget = require("Widget")
local Window = require("Window")
local Panel  = require("Panel")
local Static = require("Static")
local Button = require("Button")

local FONT       = "DejaVuLGCSans.ttf"

-- Forward slashes throughout. Windows file APIs take them, nothing needs escaping,
-- and the same strings work under a test harness on another host.
local configPath = lfs.writedir() .. "Config/MarkPresetsConfig.lua"

-- Written immediately before any unproven native call, naming it, and removed
-- immediately after. Its presence at startup means that call did not return last time,
-- so that one call is disabled for good. Delete the file to let it try again.
local probeMarkerPath = lfs.writedir() .. "Config/MarkPresets-probe.marker"
local logPath    = lfs.writedir() .. "Logs/MarkPresets.log"

-- ============================================================ logging

-- WARN is the default: silent while everything works, and it still reports a broken
-- config, an unmatched mission and the mission name to copy. INFO adds what loaded and
-- what was written; DEBUG adds the mechanics. "off" suppresses everything after the
-- banner, which stays so an empty log still means the hook never loaded.
local LEVELS = { off = 0, error = 1, warn = 2, info = 3, debug = 4 }
local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG" }
local logLevel = LEVELS.warn

-- "w": a fresh file per DCS run. Copy it before relaunching to keep a session.
local logFile = ENABLED and io.open(logPath, "w") or nil

-- Flushed per line: a crash loses what is buffered, and that is when the last line
-- matters. Text mode already translates "\n" to CRLF, so "\r\n" would double it.
local function logAt(level, fmt, ...)
  if not logFile or level > logLevel then return end
  -- A mismatched format string must not take the hook down.
  local ok, msg = pcall(string.format, fmt, ...)
  logFile:write(string.format("%s  %-5s  %s\n",
    os.date("%H:%M:%S"), LEVEL_NAMES[level],
    ok and msg or ("LOG FORMAT FAILED: " .. tostring(fmt))))
  logFile:flush()
end

-- One per level. Everything below logs through these, never logAt directly.
local function logE(fmt, ...) logAt(1, fmt, ...) end
local function logW(fmt, ...) logAt(2, fmt, ...) end
local function logI(fmt, ...) logAt(3, fmt, ...) end
local function logD(fmt, ...) logAt(4, fmt, ...) end

-- "1 button" / "2 buttons"
local function plural(n) return n == 1 and "" or "s" end

-- One log line per event, with breaks shown rather than dropped.
local function oneLine(str)
  if type(str) ~= "string" then return tostring(str) end
  return (str:gsub("\r?\n", "\\n"))
end

-- Writes the log header. Raw writes, so it appears whatever the level.
local function banner()
  if not logFile then return end
  local function raw(line) logFile:write(line .. "\n") end
  raw("================================================================")
  raw(" MarkPresets " .. VERSION)
  raw(" Started     " .. os.date("%Y-%m-%d %H:%M:%S"))
  raw(" Config      " .. configPath)
  raw(" Detail      set logLevel = \"debug\" in the config to see the mechanics")
  raw("")
  raw(" If this file is empty below here, the hook itself failed to load.")
  raw(" Load-time errors go to Logs\\dcs.log, never to this file.")
  raw("================================================================")
  logFile:flush()
end

-- Runs fn and returns its first result, or nil after logging. Lua-side only: not
-- protection against a bad argument to a native call.
local function guard(what, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    logE("%s failed: %s", what, tostring(result))
    return nil
  end
  return result
end

-- ============================================================ unproven native calls

-- pcall cannot catch an access violation, so a call whose safety is unproven is named
-- in a file, made, and the file cleared. A marker surviving a restart means that call
-- did not return, and it stays disabled. One crash, one restart, one answer.
--
-- Probed:
--   held handle read   first WidgetGetVisible of the session on a held dialog root
--   callback removal at mission end   WidgetRemoveCallback on a dialog whose mission
--                                     is ending; the same call is clean elsewhere
--   teardown           destroying our own widgets at mission end
local probeDisabled = {}

-- Failure here means the tracking model is wrong, so the hook stops rather than
-- carrying on without it.
local FATAL_PROBES = { ["held handle read"] = true }
local hookDisabled = false

-- Reads a marker left by a call that never returned and blacklists that call for this
-- session -- or disables the hook outright, if that call was a fatal one. Runs once,
-- before anything else might make one.
local function checkProbeMarker()
  local f = io.open(probeMarkerPath, "r")
  if not f then return end
  local stage = f:read("*l")
  f:close()

  stage = (type(stage) == "string" and stage ~= "") and stage or "unknown"
  probeDisabled[stage] = true

  if FATAL_PROBES[stage] then
    hookDisabled = true
    logE("MarkPresets is disabled. A previous %s took DCS down, which means mark dialog " ..
      "handles no longer stay valid the way this hook depends on -- most likely a DCS " ..
      "update. Delete %s to try again, ideally after checking for a newer MarkPresets.",
      stage, probeMarkerPath)
  else
    logW("A previous %s call did not return, so it will not be attempted again. Delete " ..
      "%s to try once more.", stage, probeMarkerPath)
  end
end

-- Runs fn under the marker. Returns nil if this call is blacklisted, otherwise the
-- pcall status -- a Lua error is reported but does not blacklist, since only a call
-- that never returns at all leaves the marker behind.
local function probe(stage, fn, ...)
  if probeDisabled[stage] then return nil end

  local f = io.open(probeMarkerPath, "w")
  if f then
    f:write(stage, "\n")
    f:write("This file names a native call that was in progress. If it is still here " ..
      "at startup, that call did not return and it will stay disabled until this file " ..
      "is deleted.\n")
    f:flush()
    f:close()
  end

  local ok, err = pcall(fn, ...)
  os.remove(probeMarkerPath)

  if not ok then logW("%s raised: %s", stage, tostring(err)) end
  return ok
end

-- ============================================================ config

local cfg

-- ---------------------------------------------------------------- tuning
--
-- Layout, in pixels. Two sets, chosen per mission entry by `compact`: the tight one
-- trades comfortable targets for map you can still see. Geometry of one panel, so it
-- is decided once when that panel is built, never per preset. Row height is absent
-- because it follows fontSize, which is configurable.
--
--   pad         inset from the panel edge to its content
--   gap         between buttons, and between wrapped rows
--   padX        horizontal text padding inside a button
--   minW        keeps a one- or two-character label clickable
--   sectionGap  extra space above each section after the first
--   rowExtra    added to fontSize for the row height
local METRICS = {
  normal  = { pad = 6, gap = 4, padX = 10, minW = 40, sectionGap = 4, rowExtra = 9 },
  compact = { pad = 3, gap = 2, padX =  6, minW = 28, sectionGap = 2, rowExtra = 4 },
}

-- The set in force for the panel currently built. Assigned by build(), read by
-- everything that lays out or measures a widget.
local M = METRICS.normal

-- observed: a created dialog's origin lands on the click, or up to 21px up and left.
-- The band is asymmetric to exclude a neighbour's window down-right of the click,
-- with a little slack the other way so an exact hit is not on its own boundary.
local NEW_DIALOG_TOLERANCE = 25
local NEW_DIALOG_SLACK     = 2

-- observed: typed input truncates at five display lines, at 165 and at 160 characters
-- depending on where the wrap fell -- about 33 to a line in the 274px body. Word wrap
-- breaks at spaces, so this is an average. Text beyond five lines has preceded a crash.
local MARK_MAX_LINES      = 5
local MARK_CHARS_PER_LINE = 33

-- Marks where the caret should land after a write. Always removed from the text,
-- autoCommit presets included, so no marker can reach a mark. A bare "|" would be a
-- worse choice: it turns up in callsigns and hand-drawn tables.
local CARET_TOKEN = "{|}"

-- Past this between press and release the gesture was a pan, not a click. Stops a map
-- drag that releases inside a dialog's text box being read as a click into it. Biased
-- generous: a pan read as a click wastes probes, a click read as a pan is lost.
local CLICK_DRAG_THRESHOLD_PX = 8

-- Shift toward white for hover and pressed, 0-1. Pressed goes brighter than hover, not
-- darker: the write is instant, so a flash reads as fired rather than held. Past about
-- 0.25 the label's contrast drops below readable.
local HOVER_SHIFT   = 0.10
local PRESSED_SHIFT = 0.22

-- Luma thresholds, 0-255, BT.601. Above SHIFT_FLIP a colour shifts toward black rather
-- than white, so a near-white button keeps visible states; above TEXT_FLIP its label
-- goes black.
local SHIFT_FLIP = 190
local TEXT_FLIP  = 140

-- fontSize drives every row height and every skin.
local MIN_FONT_SIZE = 6
local MAX_FONT_SIZE = 32

-- A preset with no `name` is labelled from its text, flattened and cut to this.
local MAX_DERIVED_NAME = 24

-- ------------------------------------------------------------------------

local DEFAULTS = {
  fontSize             = 11,

  -- off, error, warn, info, debug.
  logLevel             = "warn",

  -- 0xRRGGBB as a number, no alpha; the string dxgui wants is built in the skins
  -- section. Settable per mission entry, section or preset, nearest wins.
  --
  -- measured: the panel is 85% opaque, so the map through it puts its effective luma
  -- between about 36 over dark terrain and 75 over snow. A base near 60 vanishes over
  -- anything bright; 27 stays below it everywhere, and for a grey luma is the channel.
  buttonColor          = 0x1b1b1b,

  -- false: write the text and leave it, so the user's click away sends the mark, as
  -- typing does. true: send it on the click. Settable at all four levels.
  --
  -- measured against a mission-side mark-change counter: off, a preset click produced
  -- no event and the next click on the map produced exactly one carrying that text.
  -- DCS sends on a defocus only when the text differs from what was last sent, so
  -- browsing presets sends one per change, not one per click.
  autoCommit           = false,

  -- Tighter padding, gaps and rows, for the whole widget.
  compact              = false,

  -- "rows"  buttons wrap under section headers; as tall as the presets need.
  -- "strip" one row, section order, wheel-scrolled sideways. One row tall whatever the
  --         preset count. No headers: a single line has nowhere to put them.
  --
  -- measured: a widget carrying a wheel handler consumes the wheel while the cursor is
  -- over it, whatever the handler returns -- so it is attached only in strip mode,
  -- where blocking map zoom over the strip is the point.
  layout               = "rows",

  profiles             = {},
}

local LAYOUTS = { rows = true, strip = true }

-- True if n is a usable 0xRRGGBB value. Eight-digit values are the likely mistake and
-- are reported as such rather than silently misread.
local function validColor(n, what, warn)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
    if warn then
      warn("%s should be a colour number like 0xRRGGBB -- ignoring %s", what, tostring(n))
    end
    return false
  end
  if n > 0xffffff then
    if warn then
      warn("%s is out of range. Colours here are six hex digits with no alpha, so " ..
        "0x%06x rather than 0x%x.", what, math.floor(n / 256) % 0x1000000, n)
    end
    return false
  end
  return true
end

-- First of `own` and `inherited` that is usable. A bad value costs this level its
-- setting, not the whole entry.
local function inheritColor(own, inherited, what)
  if own == nil then return inherited end
  if validColor(own, what, logW) then return own end
  return inherited
end

-- Separate from inheritColor because a boolean's "unset" and its `false` are different
-- things, and `own or inherited` would turn an explicit false back into the level above.
local function inheritBool(own, inherited, what)
  if own == nil then return inherited end
  if type(own) == "boolean" then return own end
  logW("%s should be true or false -- ignoring %s", what, tostring(own))
  return inherited
end

local function hex6(v) return string.format("0x%06x", v) end

-- Top-level keys that are checked on the way in, and what a good value looks like.
-- validColor warns for itself, because "you gave eight hex digits" is worth saying.
local CHECKS = {
  { "buttonColor", function(v) return validColor(v, "buttonColor", logW) end,
    "a colour like 0xRRGGBB", hex6 },
  { "autoCommit", function(v) return type(v) == "boolean" end, "true or false" },
  { "compact",    function(v) return type(v) == "boolean" end, "true or false" },
  { "layout",     function(v) return type(v) == "string" and LAYOUTS[v] ~= nil end,
    '"rows" or "strip"' },
  { "fontSize",   function(v) return type(v) == "number" and v > 0 end,
    "a positive number" },
}

-- Characters, not bytes: the dialog wraps on glyphs, and DCS ships marks in Cyrillic,
-- where counting bytes would report every preset at twice its length. Counts UTF-8
-- lead bytes, i.e. everything outside the 0x80-0xBF continuation range.
local function charCount(str)
  local n = 0
  for _ in str:gmatch("[^\128-\191]") do n = n + 1 end
  return n
end

-- Estimated display lines, counting explicit breaks and wrapping at the dialog's width.
local function displayLines(text)
  local lines = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines = lines + math.max(1, math.ceil(charCount(line) / MARK_CHARS_PER_LINE))
  end
  return lines
end

-- Returns the text with every marker removed, and where the first one was in
-- characters, or nil for no marker.
--
-- measured: EditBoxGetLineTextLength counts characters, not bytes ("РЛСxy" reported 5
-- against 8), and a newline is a separator that is not itself a character. So the
-- offset is codepoints with newlines uncounted.
local function splitCaret(text)
  local at = text:find(CARET_TOKEN, 1, true)
  if not at then return text, nil end

  local before = text:sub(1, at - 1)
  local rest   = text:sub(at + #CARET_TOKEN)

  -- Only the first marker positions the caret; the rest are removed anyway, since one
  -- reaching a mark is worse than ignoring it.
  local extra = rest:find(CARET_TOKEN, 1, true)
  while extra do
    rest  = rest:sub(1, extra - 1) .. rest:sub(extra + #CARET_TOKEN)
    extra = rest:find(CARET_TOKEN, 1, true)
  end

  local offset = 0
  for _ in before:gmatch("[^\128-\191]") do offset = offset + 1 end
  for _ in before:gmatch("\n")           do offset = offset - 1 end

  -- An offset on a line boundary is two places: end of one line, start of the next.
  -- Identical after a soft wrap, visibly different after a hard newline. This flags
  -- which; setCaret picks its comparison to match.
  return before .. rest, offset, before:sub(-1) == "\n"
end

-- Label for a preset with no `name`: one line, short enough to stay a button.
local function derivedName(text)
  local flat = text:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  if charCount(flat) <= MAX_DERIVED_NAME then return flat end
  -- Cut on a character boundary: a byte cut leaves half a Cyrillic letter.
  local out, n = {}, 0
  for ch in flat:gmatch("[^\128-\191][\128-\191]*") do
    n = n + 1
    if n > MAX_DERIVED_NAME - 1 then break end
    out[#out + 1] = ch
  end
  return table.concat(out) .. "\226\128\166"   -- U+2026 HORIZONTAL ELLIPSIS
end

-- Row height follows the font rather than being a separate knob, so raising fontSize
-- does not clip the text it is meant to enlarge. Headers use the same height as
-- buttons: same font, same box, so they sit on the same vertical rhythm.
-- Follows the font, so raising fontSize does not clip the text it enlarges. Headers
-- use the same height, so they share the buttons' vertical rhythm.
local function rowH() return cfg.fontSize + M.rowExtra end

cfg = DEFAULTS


-- Usable sections from one mission entry. Bad ones are skipped individually, so a
-- malformed preset costs one button. Inherited settings are resolved down to each
-- preset and stored there, so nothing downstream walks the levels again.
local function validateSections(raw, where, inheritedColor, inheritedAuto)
  local sections = {}
  for si, sec in ipairs(type(raw) == "table" and raw or {}) do
    if type(sec) ~= "table" then
      logW("%s: section %d is not a table -- skipped", where, si)
    else
      -- Resolved before this section's presets, so each inherits from its own section.
      local sectionColor = inheritColor(sec.buttonColor, inheritedColor,
                             string.format("%s section %d buttonColor", where, si))
      local sectionAuto  = inheritBool(sec.autoCommit, inheritedAuto,
                             string.format("%s section %d autoCommit", where, si))

      local presets = {}
      for pi, prst in ipairs(type(sec.presets) == "table" and sec.presets or {}) do
        if type(prst) ~= "table" or type(prst.text) ~= "string" or prst.text == "" then
          logW("%s: section %d, preset %d has no `text` -- skipped", where, si, pi)

        else
          local what = string.format("%s section %d, preset %d", where, si, pi)

          -- Marker out first: everything below works on the text that gets written.
          local body, caretAt, caretStrict = splitCaret(prst.text)
          local auto = inheritBool(prst.autoCommit, sectionAuto, what .. " autoCommit")

          if caretAt and auto then
            logW("%s places the caret with %s but also sets autoCommit, which sends the " ..
              "mark immediately and leaves nothing to type into. The marker is removed " ..
              "from the text either way; the caret is ignored.", what, CARET_TOKEN)
          end

          -- Kept, not refused: this is an estimate, and refusing on one would remove
          -- working buttons. Reported at load, where it can still be fixed.
          local needed = displayLines(body)
          if needed > MARK_MAX_LINES then
            logW("%s needs about %d lines and the mark dialog shows %d. Long text has " ..
              "preceded a DCS crash -- shorten it, or split it across presets. " ..
              "(%d characters, wrapping at about %d to a line.)",
              what, needed, MARK_MAX_LINES, charCount(body), MARK_CHARS_PER_LINE)
          end

          -- Flattened: a Button label containing "\n" renders as one clipped line in a
          -- box sized for the whole string. Marker-free, so no button shows one.
          local name = (type(prst.name) == "string" and prst.name ~= "")
                       and prst.name or derivedName(body)

          presets[#presets + 1] = {
            name = name,
            text = body,
            caretAt = (not auto) and caretAt or nil,
            caretStrict = caretStrict,
            buttonColor = inheritColor(prst.buttonColor, sectionColor,
                            what .. " buttonColor"),
            autoCommit  = auto,
          }
        end
      end
      if #presets == 0 then
        logW("%s: section %d has no usable presets -- skipped", where, si)
      else
        sections[#sections + 1] = {
          header  = type(sec.header) == "string" and sec.header ~= "" and sec.header or nil,
          presets = presets,
        }
      end
    end
  end
  return sections
end

-- Reads and validates the config into `cfg`. Never throws and never prevents the
-- hook loading: a broken config leaves it loaded and idle.
local function loadConfig()
  local tbl = guard("read config", Tools.safeDoFile, configPath, true)
  local user = (type(tbl) == "table" and type(tbl.MarkPresets) == "table") and tbl.MarkPresets or nil
  if not user then
    logE("Could not read the config file, so MarkPresets has nothing to show. Check " ..
      "that %s exists and is valid Lua -- a syntax error in it is reported in dcs.log. " ..
      "A default ships as MarkPresetsConfig.lua.example in the same folder: rename it, " ..
      "dropping .example, and restart DCS.", configPath)
    return
  end

  local out = {}
  for k, v in pairs(DEFAULTS) do out[k] = v end
  for k, v in pairs(user) do
    if DEFAULTS[k] ~= nil then
      out[k] = v
    else
      -- Almost always a typo -- `buttonColour`, `mission` for `missions` -- and
      -- ignoring it silently is what makes a config look applied when it is not.
      logW("Config key %q is not one this hook reads, so it has no effect. The keys " ..
        "at the top level are fontSize, logLevel, buttonColor, autoCommit, " ..
        "compact, layout and profiles.", tostring(k))
    end
  end

  -- Applied before validation so a debug run shows the validation detail too.
  if type(out.logLevel) == "string" and LEVELS[out.logLevel:lower()] then
    logLevel = LEVELS[out.logLevel:lower()]
    -- At the level just selected, so "warn" does not suppress its own confirmation.
    -- At the selected level, so it is not suppressed by its own setting. Skipped for
    -- "off", which has no level to log at.
    if logLevel > LEVELS.off and logLevel ~= LEVELS.warn then
      logAt(logLevel, "Log level: %s", out.logLevel:lower())
    end
  elseif out.logLevel ~= DEFAULTS.logLevel then
    logW("logLevel %q is not one of off/error/warn/info/debug -- staying on %s",
      tostring(out.logLevel), DEFAULTS.logLevel)
  end

  -- Checked before the mission entries, which inherit from these. A bad value costs
  -- that key its setting, never the whole config.
  for _, c in ipairs(CHECKS) do
    local key, ok, want, fmt = c[1], c[2], c[3], c[4]
    if not ok(out[key]) then
      local d = DEFAULTS[key]
      logW("%s should be %s -- using %s", key, want, fmt and fmt(d) or tostring(d))
      out[key] = d
    end
  end

  -- Bounded rather than rejected: a fontSize outside this range is a mistake, and both
  -- an unreadable panel and one taller than the screen read as the hook being broken.
  if out.fontSize < MIN_FONT_SIZE or out.fontSize > MAX_FONT_SIZE then
    local clamped = math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE, out.fontSize))
    logW("fontSize %s is outside the usable range %d-%d -- using %d",
      tostring(out.fontSize), MIN_FONT_SIZE, MAX_FONT_SIZE, clamped)
    out.fontSize = clamped
  end

  local groups = {}
  for mi, entry in ipairs(type(user.profiles) == "table" and user.profiles or {}) do
    if type(entry) ~= "table" then
      logW("Profile %d is not a table -- skipped", mi)
    else
      -- A profile is matched on two axes, mission and server, each by exact name or by
      -- pattern. An axis with neither key is no constraint; a profile with none at all
      -- is skipped rather than silently becoming a catch-all.
      local function str(v) return (type(v) == "string" and v ~= "") and v or nil end
      local exact   = str(entry.mission)
      local pattern = str(entry.missionPattern)
      local srv     = str(entry.server)
      local srvPat  = str(entry.serverPattern)

      local bits = {}
      if exact   then bits[#bits+1] = string.format("mission %q", exact) end
      if pattern then bits[#bits+1] = string.format("missionPattern %q", pattern) end
      if srv     then bits[#bits+1] = string.format("server %q", srv) end
      if srvPat  then bits[#bits+1] = string.format("serverPattern %q", srvPat) end
      local describe = table.concat(bits, " + ")

      if #bits == 0 then
        logW("Profile %d names neither a mission nor a server -- skipped. Add one of " ..
          "mission, missionPattern, server or serverPattern, or use " ..
          "missionPattern = \"*\" to match everywhere.", mi)
      else
        local where = string.format("Profile %d (%s)", mi, describe)

        -- This entry's settings, falling back to the config's own. Resolved before the
        -- sections so a preset inherits from its group, not from the global directly.
        local groupColor = inheritColor(entry.buttonColor, out.buttonColor,
                             where .. " buttonColor")
        local groupAuto  = inheritBool(entry.autoCommit, out.autoCommit,
                             where .. " autoCommit")

        local groupLayout = out.layout
        if entry.layout ~= nil then
          if type(entry.layout) == "string" and LAYOUTS[entry.layout] then
            groupLayout = entry.layout
          else
            logW("%s layout %q is not \"rows\" or \"strip\" -- using %q", where,
              tostring(entry.layout), groupLayout)
          end
        end

        local sections = validateSections(entry.sections, where, groupColor, groupAuto)
        if #sections == 0 then
          logW("%s has no usable sections -- skipped", where)
        else
          local buttons = 0
          for _, sec in ipairs(sections) do buttons = buttons + #sec.presets end
          groups[#groups + 1] = {
            mission = exact, missionPattern = pattern,
            server  = srv,   serverPattern  = srvPat,
            describe = describe,
            sections = sections, buttons = buttons, layout = groupLayout,
          }
          logI("Profile %d: %s -- %d section%s, %d button%s, %s layout",
            #groups, describe, #sections, plural(#sections),
            buttons, plural(buttons), groupLayout)
        end
      end
    end
  end

  out.profiles = groups
  cfg = out
  logI("Config loaded: %d profile%s", #groups, plural(#groups))
end

-- ============================================================ mission gating

-- Checked first by the frame handler and every mouse handler: off costs one boolean
-- test per frame.
local enabled = false
local activeEntry = nil

-- Leading and trailing whitespace off, so a config entry with a stray space matches.
local function trim(str) return (str:match("^%s*(.-)%s*$")) end

-- Does `name` match a `...Pattern`? Tried cheapest and most predictable first, so the
-- common case needs no knowledge of Lua patterns:
--
--   "*"      every mission
--   literal  the text appears anywhere in the name, ignoring case. This is what plain
--            text does, and it is why a name full of Lua's magic characters --
--            "(v2.1)", "Op - Bandit" -- works without escaping any of them.
--   pattern  a Lua pattern, case-sensitive, for anchors and wildcards.
--
-- Returns matched, or nil plus a message when the pattern itself is unusable.
local function textMatches(name, pat)
  if pat == "*" then return true end
  if name:lower():find(pat:lower(), 1, true) then return true end
  local ok, hit = pcall(string.find, name, pat)
  if not ok then return nil, hit end
  return hit ~= nil
end

-- Last mission name evaluated, so the second lifecycle callback does not re-log.
local lastEvaluated = nil

-- The connected server's name, or nil in single player and whenever it cannot be read.
--
-- measured as a client on a live server: net.get_server_settings() returns the
-- CONNECTED server's settings -- its name came back where net.get_default_server_settings
-- says "DCS Server" -- so the two are not the same table. Fails closed, so a profile
-- naming a server never matches when the name is unknown.
local function serverName()
  if type(net) ~= "table" or type(net.get_server_settings) ~= "function" then return nil end
  local okM, mp = pcall(DCS.isMultiplayer)
  if not okM or not mp then return nil end
  local ok, t = pcall(net.get_server_settings)
  if ok and type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
    return t.name
  end
  return nil
end

-- Are we occupying an aircraft? Nothing runs otherwise: presets belong to a pilot
-- marking their own map, not to a spectator watching one.
--
-- measured in a cockpit on a live server: net.get_slot(id) returned side 2 and slot
-- "1002769". The slot is "" in spectator and still "" after choosing a coalition, so a
-- non-empty slot string is the signal. Single player has no slot list, where having a
-- player unit is the same question.
local function slotted()
  local okM, mp = pcall(DCS.isMultiplayer)
  if okM and mp then
    if type(net) ~= "table" or type(net.get_slot) ~= "function" then return false end
    local okId, id = pcall(net.get_my_player_id)
    if not okId or id == nil then return false end
    local okS, _, slot = pcall(net.get_slot, id)
    return okS and type(slot) == "string" and slot ~= ""
  end
  local okU, unit = pcall(DCS.getPlayerUnit)
  return okU and unit ~= nil and unit ~= ""
end

-- Slot state changes mid-session, so it is polled rather than settled at mission load.
-- Slow: two seconds late to notice a seat change costs nothing. Every caller goes
-- through refreshSlot rather than reading `inSlot`, so a click arriving before the
-- first frame is answered rather than dropped.
local SLOT_POLL = 2.0
local inSlot = false
local lastSlotCheck = nil

local function refreshSlot(now)
  if lastSlotCheck and (now - lastSlotCheck) < SLOT_POLL then return inSlot end
  lastSlotCheck = now
  local was = inSlot
  inSlot = slotted()
  if inSlot ~= was then
    logI(inSlot and "In a seat: presets are available."
                 or "Not in a seat: presets are off until you slot in.")
  end
  return inSlot
end

-- One axis of a profile: an exact name, a pattern, or neither. Neither is no
-- constraint, so a profile naming only a server matches every mission on it.
-- Returns matched, plus any pattern error for reporting.
local function axisMatches(name, exact, pat)
  if not exact and not pat then return true end
  if not name then return false end
  if exact and trim(exact):lower() == trim(name):lower() then return true end
  if not pat then return false end
  local hit, err = textMatches(name, pat)
  if hit == nil then return false, err end
  return hit
end

-- Decides whether this mission gets presets, setting `enabled` and `activeEntry`.
-- Fails closed: without a mission name the hook stays idle.
local function evaluateMission()
  enabled, activeEntry = false, nil

  -- Only the FIRST held-handle read goes through the marker, so without this the
  -- second would dereference the same handle unguarded.
  if hookDisabled then return end

  local okN, name = pcall(DCS.getMissionName)
  name = (okN and type(name) == "string" and name ~= "") and name or nil
  local server = serverName()

  -- onMissionLoadEnd and onSimulationStart both fire, either first, so this runs twice
  -- per load. Every report below is gated on this: a doubled block reads as two
  -- missions, and a doubled warning as two failures.
  local repeated = (name == lastEvaluated)
  lastEvaluated = name

  -- Logged every load: the exact string is what has to go in the config.
  -- Both are logged every load: they are exactly what has to go in the config.
  if not repeated then
    logI("Mission: %s", name and string.format("%q", name) or "(unavailable)")
    if server then logI("Server:  %q", server) end
  end

  if #cfg.profiles == 0 then
    if not repeated then logW("Idle: the config defines no profiles.") end
    return
  end

  if not name and not server then
    if not repeated then
      logW("Idle: DCS reported neither a mission name nor a server, so there is no way " ..
        "to tell which profile applies.")
    end
    return
  end

  for i, entry in ipairs(cfg.profiles) do
    local mOK, mErr = axisMatches(name,   entry.mission, entry.missionPattern)
    local sOK, sErr = axisMatches(server, entry.server,  entry.serverPattern)

    if not repeated then
      if mErr then
        logW("Profile %d has an unusable missionPattern %q: %s. Plain text is matched " ..
          "literally, so this only happens with Lua pattern syntax.",
          i, tostring(entry.missionPattern), tostring(mErr))
      end
      if sErr then
        logW("Profile %d has an unusable serverPattern %q: %s. Plain text is matched " ..
          "literally, so this only happens with Lua pattern syntax.",
          i, tostring(entry.serverPattern), tostring(sErr))
      end
    end

    if mOK and sOK then
      enabled, activeEntry = true, i
      if not repeated then
        logI("Active: profile %d (%s). %d button%s available.",
          i, entry.describe, entry.buttons, plural(entry.buttons))
      end
      return
    end
  end

  if not repeated then
    logW("Idle: no profile matches. To use MarkPresets here, add one to %s with:  " ..
      "mission = %q%s", configPath, tostring(name),
      server and string.format(", server = %q", server) or "")
  end
end

-- ============================================================ handles

-- A handle is userdata. A number is truthy but passing one where a handle is expected
-- is an access violation.
local function isHandle(v) return type(v) == "userdata" end

-- True if our own Lua state created this widget. Widget.widgets holds only ours, so
-- this is exact, and it is what stops hit tests treating our panel as a DCS dialog.
local function isOurs(h)
  return isHandle(h) and Widget.widgets[h] ~= nil
end

-- Named lookup, engine-side: what dxgui\bind\Widget.lua's findByName calls and what
-- DialogLoader resolves dialogs with. One native call per name.
local function findChild(parent, name)
  if not isHandle(parent) then return nil end
  local ok, w = pcall(dxgui.WidgetFindWidgetByName, parent, name)
  if ok and isHandle(w) then return w end
  return nil
end

-- Returns { edit, id, body, head } for a mark dialog root, or nil if it is not one.
--
-- observed: a mark dialog is Window > { bodyPanel > eMarkLable, headePanel > sMarkId },
-- from Scripts\UI\F10View\MarkPanel.dlg.
--
-- measured on 2.9.29.27278: WidgetFindWidgetByName searches the whole subtree, and a
-- miss returns nil without raising -- so the root lookup answers and the per-panel
-- fallback never runs. The fallback stays as insurance against a build where it does
-- not, and costs nothing while the root lookup keeps working.
--
-- `edit` is resolved first and its absence ends the call, so an unrelated DCS dialog
-- costs two native calls rather than four.
local function markWidgets(root)
  local body = findChild(root, "bodyPanel")
  local edit = findChild(root, "eMarkLable") or (body and findChild(body, "eMarkLable"))
  if not edit then return nil end

  local head = findChild(root, "headePanel")
  local id   = findChild(root, "sMarkId") or (head and findChild(head, "sMarkId"))

  return { edit = edit, id = id, body = body, head = head }
end

-- Height of the edit box's TEXT CONTENT, not the box, which is permanently 274x127.
-- The dialog's height is this plus a fixed chrome offset.
local function contentHeight(edit)
  local ok, _, h = pcall(dxgui.WidgetCalcSize, edit)
  if ok and type(h) == "number" and h > 0 then return h end
  return nil
end

-- Screen rect, or nil if either read fails or the values are unusable.
-- WidgetGetPosition is screen coordinates for a root and parent-relative for a child,
-- so children go through WidgetToScreen instead.
local function rectVia(posFn, widget, ...)
  local okP, x, y = pcall(posFn, widget, ...)
  local okS, w, h = pcall(dxgui.WidgetGetSize, widget)
  if okP and okS and type(x) == "number" and type(w) == "number" and w > 0 then
    return x, y, w, h
  end
  return nil
end

local function windowRect(root)   return rectVia(dxgui.WidgetGetPosition, root) end
local function screenRect(widget) return rectVia(dxgui.WidgetToScreen, widget, 0, 0) end

-- Returns the top-level window handle under a screen point, or nil.
local function rootAt(x, y)
  local okF, w = pcall(dxgui.FindWidgetAtScreenPoint, math.floor(x), math.floor(y))
  if not okF or not isHandle(w) then return nil end
  local okR, r = pcall(dxgui.WidgetGetRoot, w)   -- never call with no argument
  if okR and isHandle(r) then return r end
  return nil
end

-- The hit-test space is whatever GetScreenSize reports, which is NOT the monitor size:
-- in VR it is smaller. Re-read periodically so a 2D/VR switch mid-session is picked up.
local screenW, screenH = nil, nil
local lastScreenCheck = nil
local screenWarned = false

-- All timing is os.clock(), never DCS.getModelTime: model time stops while the sim is
-- paused -- observed frozen for seconds of wall clock with onSimulationFrame still
-- firing -- and planning marks while paused is ordinary. os.clock is wall time on the
-- Windows CRT, which is what is wanted here.
local function refreshScreen(now)
  if screenW and now and lastScreenCheck and (now - lastScreenCheck) < 5 then
    return true
  end
  lastScreenCheck = now

  local ok, w, h = pcall(dxgui.GetScreenSize)
  if ok and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
    if w ~= screenW or h ~= screenH then
      logI("Screen area for clicks: %dx%d", w, h)
    end
    screenW, screenH, screenWarned = w, h, false
    return true
  end

  if not screenW and not screenWarned then
    -- Once, not per retry: the retry runs every five seconds with a flush per line.
    screenWarned = true
    logW("dxgui.GetScreenSize did not answer, so the screen bounds are unknown. " ..
      "Holding off until it does rather than guessing a resolution.")
  end
  return screenW ~= nil
end

-- ============================================================ mark dialog

-- The dialog currently followed: its root, edit box, body and header panels, its mark
-- id, and the chrome offset measured when it was adopted.
local tracked = nil

-- Returns a widget's text, or nil if it has none or cannot be read.
local function textOf(h)
  if not h then return nil end
  local ok, txt = pcall(dxgui.WidgetGetText, h)
  if ok and type(txt) == "string" then return txt end
  return nil
end

-- Debug only, read included: WidgetGetText on a DCS-owned widget purely for a log line.
local function logBoxText(edit, fmt)
  if logLevel < LEVELS.debug then return end
  local txt = textOf(edit)
  logD(fmt, txt and #txt or 0, plural(txt and #txt or 0),
    txt and txt ~= "" and oneLine(txt) or "(empty)")
end

-- measured: mark dialogs are only ever hidden, never destroyed -- by minimise,
-- btnClose, closing the map, and by mission scripting deleting the mark, where the
-- root still answered and its panels kept their children. That is what makes holding a
-- handle safe, and the first held read of the session is marker-guarded in case a DCS
-- update changes it.
--
-- A mark-dialog-only exception. Any other DCS-owned widget is re-resolved by hit test
-- and dereferenced only in the frame that found it.
local firstHeldRead = true

-- checkParentVisibility is not optional: without it the widget's own flag comes back,
-- and that does not change when the map window closes.
local function dialogVisible(root)
  if firstHeldRead then
    firstHeldRead = false
    local vis
    local ran = probe("held handle read", function()
      local ok, v = pcall(dxgui.WidgetGetVisible, root, true)
      vis = ok and v
    end)
    if ran == nil then return false end
    return vis == true
  end

  local ok, v = pcall(dxgui.WidgetGetVisible, root, true)
  return (ok and v) == true
end

-- x, bottom, width, top, screen coordinates, from the held handles.
--
-- measured: the window is 306x75 for a one-line mark; bodyPanel is 274x127 at
-- window-local 24,59 and headePanel 274x34 at 24,25, both constant as the window grows.
-- So x and width come from bodyPanel, which matches the visible dialog rather than the
-- wider window; the bottom is the window's, because bodyPanel's own bottom sits far
-- below it; and the top is headePanel's, the window's being ~25px of invisible margin
-- higher. All clamped into the window rect.
local function placement(rx, ry, rw, rh)
  local x, w    = rx, rw
  local bottom  = ry + rh
  local top     = ry

  local bx, by, bw, bh = screenRect(tracked.body)
  if bx then
    if bw <= rw and bx >= rx - 2 and (bx + bw) <= (rx + rw + 2) then x, w = bx, bw end
    if (by + bh) < bottom then bottom = by + bh end
  end

  local _, hy = screenRect(tracked.head)
  if hy and hy > ry and hy < bottom then top = hy end

  return x, bottom, w, top
end

-- Dialogs already carrying our callbacks, keyed by mark id: registering twice would
-- leak a second pair of closures.
local registeredMarks = {}

-- How often the dialog is checked for having been hidden. Slow on purpose: nothing
-- announces a deleted mark or a closed map, so this is what notices, and a beat late
-- costs nothing.
local VISIBILITY_POLL = 0.15
local lastCheck = 0

-- Ceiling on how long placement may disagree with itself before the panel is shown
-- anyway. Without it, a dialog that never settles resolves every frame and shows
-- nothing for it.
local SETTLE_TIMEOUT = 1.0
local settleStarted = nil

-- Fallback for when the panel cannot simply be moved. Position tracking is otherwise
-- entirely event-driven; nothing polls for it.
--
--   widget position  fires continuously as the dialog moves -- 181 fires across one pan
--   widget size      fires only on a real change; WidgetSetSize to the current size
--                    fires nothing, and it arrives synchronously from inside that call
--
-- `window close` is not registered: nothing in DCS calls WindowClose, and a deleted
-- mark or a closed map fires nothing at all, which is why the visibility poll stays.
local replaceRequested = false

-- Assigned in the callbacks section, once place() and the settle state exist; declared
-- here because registerDialogCallbacks closes over it.
local repositionNow

local DIALOG_CALLBACKS = { "widget size", "widget position" }

-- Keeps each closure on `tracked`: WidgetRemoveCallback needs the original function
-- value, not just the type.
local function registerDialogCallbacks(markId)
  -- Before the guard: nil here on the early return would leave detach with nothing to
  -- remove from a dialog that does carry our callbacks.
  tracked.callbacks = tracked.callbacks or {}
  if registeredMarks[markId] then return end
  registeredMarks[markId] = true

  for _, kind in ipairs(DIALOG_CALLBACKS) do
    -- repositionNow moves the panel if that is all this needs, and sets the flag if
    -- not. It is nil until the callbacks section assigns it.
    local fn = function()
      if repositionNow then repositionNow() else replaceRequested = true end
    end

    local ok = pcall(dxgui.WidgetAddCallback, tracked.root, kind, fn)
    logD("Registered %q on mark %s: %s", kind, markId, tostring(ok))
    if ok then tracked.callbacks[#tracked.callbacks + 1] = { kind = kind, fn = fn } end
  end
end


-- Edit box handle plus the placement anchor, or nil if the dialog is no longer showing.
--
-- No hit test and no name lookup: the handles were taken at acquisition and the dialog
-- is never destroyed. Identity never has to be re-established, so probe points,
-- tolerances, sMarkId re-matching and self-occlusion all stop applying.
--
-- A hidden dialog counts as gone; re-opening one takes a click, and that re-acquires it.
-- Placement anchor for a dialog root: x, bottom, width, top, or nil if its rect
-- cannot be read.
local function anchorOf(root)
  local x, y, w, h = windowRect(root)
  if not x then return nil end
  return placement(x, y, w, h)
end

local function resolve()
  if not tracked then return nil end
  if not dialogVisible(tracked.root) then return nil end

  local px, py, pw, pt = anchorOf(tracked.root)
  if not px then return tracked.edit end
  return tracked.edit, px, py, pw, pt
end

-- Two accepted shapes, kept strictly apart:
--
--   created  this click made the dialog. Its origin lands on the click or a little up
--            and left (0,0 and -13,-13 both measured).
--   edited   the click landed inside eMarkLable, i.e. into an open dialog's text.
--
-- `edited` is tested against the edit box's rect, never the window's: the window's
-- transparent margin is hit-testable across its full extent, so "inside the window" is
-- true of whichever older dialog covers the cursor.
--
-- created beats edited: a mark placed on top of an open dialog means the new one.
--
-- `seen` belongs to the pending click and is shared across retry rungs, so a root is
-- examined once. A created dialog is a new root, so a later rung still finds it.
--
-- Probe points stay small and down-right, matching where a created dialog lands;
-- sweeping wide finds neighbouring dialogs instead.
local PROBES = { {1, 1}, {6, 6}, {16, 24}, {40, 40} }

-- Returns the root window handle of the dialog this click created or was aimed at,
-- its mark id, and the widget set resolved from it, or nil. The handles are valid only
-- in the frame this ran. Mutates `seen`.
local function acquireAt(cx, cy, seen, attempt)
  local created, createdId, createdW = nil, nil, nil
  local edited,  editedId,  editedW  = nil, nil, nil

  -- Classifies one probe point as created, edited or neither. Mutates the enclosing
  -- candidates and `seen`.
  local function try(px, py)
    local x, y = cx + px, cy + py
    if x < 0 or y < 0 or x >= screenW or y >= screenH then return end
    local root = rootAt(x, y)
    if not root or isOurs(root) or seen[root] then return end

    -- Every name in one pass: the id is needed now for identity and the panels the
    -- moment this dialog is adopted, so adoption makes no further lookups.
    local w = markWidgets(root)
    if not w then
      seen[root] = true
      return
    end

    local rx, ry, rw, rh = windowRect(root)
    if not rx then
      seen[root] = true
      return
    end

    -- No readable id, no tracking: identity is the only thing between following this
    -- dialog and retargeting to a neighbour. NOT marked seen -- sMarkId may be empty on
    -- the frame a dialog is created, and a later rung has to be free to retry.
    local id = textOf(w.id)
    if not id then
      logD("Dialog at %d,%d has no readable id yet; leaving it for a later attempt",
        rx, ry)
      return
    end

    seen[root] = true

    local dx, dy = rx - cx, ry - cy
    local tol, slack = NEW_DIALOG_TOLERANCE, NEW_DIALOG_SLACK
    if dx <= slack and dx >= -tol and dy <= slack and dy >= -tol then
      if not created then
        created, createdId, createdW = root, id, w
        logD("Found a dialog this click created: %dx%d at offset %+d,%+d from the click " ..
          "(probe %+d,%+d, attempt %d)", rw, rh, dx, dy, px, py, attempt or 0)
      end
      return
    end

    -- The edit box is already held, so its rect needs no second lookup.
    local ex, ey, ew, eh = screenRect(w.edit)
    if ex and cx >= ex and cx < ex + ew and cy >= ey and cy < ey + eh then
      if not edited then
        edited, editedId, editedW = root, id, w
        logD("Clicked into the text of an open dialog at %d,%d", rx, ry)
      end
      return
    end

    logD("Ignoring the dialog at %d,%d: offset %+d,%+d from the click at %d,%d is neither " ..
      "a new dialog nor a click into its text", rx, ry, dx, dy, cx, cy)
  end

  try(0, 0)
  for _, prb in ipairs(PROBES) do try(prb[1], prb[2]) end

  if created then return created, createdId, createdW end
  return edited, editedId, editedW
end

-- ============================================================ skins

local FALLBACK_SKINS = false

-- Lua 5.1 has no bitwise operators, so the components come out arithmetically.
-- Returns r, g, b as 0-255 from a 0xRRGGBB number.
local function rgb(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

-- ITU-R BT.601 luma, 0-255. Perceived brightness, which is what decides whether a
-- colour should lighten or darken and whether its label reads better black or white.
local function luma(r, g, b) return (r * 299 + g * 587 + b * 114) / 1000 end

-- The string form a skin table wants, from a 0xRRGGBB number. Always opaque.
local function colorString(n)
  return string.format("0x%06xff", n)
end

-- Shifts a colour toward white by `amount` (0-1), or toward black when it is already
-- too light for lightening to show. Always fully opaque: a button that differs from
-- the panel only in alpha composites into it and its bounds vanish.
local function shade(n, amount)
  local r, g, b = rgb(n)
  local target = luma(r, g, b) > SHIFT_FLIP and 0 or 255
  return string.format("0x%02x%02x%02xff",
    math.floor(r + (target - r) * amount),
    math.floor(g + (target - g) * amount),
    math.floor(b + (target - b) * amount))
end

-- White label on a dark button, black on a light one, so a per-button colour does
-- not need a second key beside it for its text.
local function textOn(n)
  local r, g, b = rgb(n)
  return luma(r, g, b) > TEXT_FLIP and "0x000000ff" or "0xffffffff"
end

-- Flat fills only. A border needs the bkg table's ring cells and an `insets` thickness,
-- unproven with no `file` set; a radius needs a pre-rounded nine-slice texture, so it
-- is not available at all. An opaque fill a step off the panel shows a button's bounds.
--
-- opts: fill, hover, pressed, disabled -- background colours, as strings
--       fg        text colour
--       centred   centre the label on both axes -- buttons
--       vcentred  centre it vertically only, leaving it left -- section headers
--       padX      horizontal textOffset
local function makeSkin(name, opts)
  local fs = cfg.fontSize

  -- One state's layer table: a background fill and the text style over it.
  local function state(fill)
    local st = {
      bkg  = { center_center = fill },
      text = { color = opts.fg or "0xffffffff", font = FONT, fontSize = fs, lineHeight = 0 },
    }
    -- Text sits left unless told otherwise, which suits a header; buttons ask for
    -- centred. Both need vertical centring or the label rides high and reads clipped.
    if opts.centred then st.text.horzAlign = { type = "middle" } end
    if opts.centred or opts.vcentred then st.text.vertAlign = { type = "middle" } end
    return { [1] = st }
  end

  local states = { released = state(opts.fill) }
  if opts.hover    then states.hover    = state(opts.hover)    end
  if opts.pressed  then states.pressed  = state(opts.pressed)  end
  if opts.disabled then states.disabled = state(opts.disabled) end

  local params = { name = name }
  if opts.padX then params.textOffset = { left = opts.padX, right = opts.padX } end
  return { skinData = { params = params, states = states } }
end

-- Fixed colours, in the string form dxgui takes. Only a button's base colour is
-- configurable; a button takes ONE colour and derives its hover and pressed states, so
-- there are not three settings to keep in step. Config colours carry no alpha: a
-- translucent button drifts toward the panel colour instead of dimming, and one
-- differing from the panel only in alpha has no visible bounds at all.
--
-- measured, from WidgetGetSkin on a live dialog and confirmed by MarkPanel.dlg's
-- inline headePanel state: header 0x2b2b2bd8, edit box 0x00000043. The panel matches
-- the HEADER so it reads as a continuation of the dialog, and at 0xd8 it is opaque
-- enough for white section labels without a bar of their own.
--
-- The window frame draws NOTHING, and that is load-bearing. The panel is 85% opaque,
-- so filling the frame puts it over near-black instead of over the map -- the same
-- 0x2b2b2bd8 then came out visibly darker than the dialog's own header. MarkPanel.dlg
-- leaves center_center unset for the same reason.
local HEADER_TEXT_COLOR = "0xffffffff"
local PANEL_COLOR      = "0x2b2b2bd8"
local HEADER_BAR_COLOR = "0x00000000"
local WINDOW_COLOR     = "0x00000000"

local skins = {}
-- Builds the window, panel and header skins into `skins`. Buttons are not here --
-- they get one skin per distinct colour, built on demand by buttonSkin.
local function buildSkins()
  skins.window = makeSkin("mpWindow", { fill = WINDOW_COLOR })
  skins.panel  = makeSkin("mpPanel", { fill = PANEL_COLOR })
  -- No padX: the header is inset to the buttons' x, so its label lines up without
  -- textOffset, which is unproven on a Static.
  skins.header = makeSkin("mpHeader", {
    fill     = HEADER_BAR_COLOR,
    fg       = HEADER_TEXT_COLOR,
    vcentred = true,
  })
end

-- One skin per distinct button colour, built on demand: fifty buttons in three colours
-- build three skins.
local buttonSkins = {}

local function buttonSkin(base)
  local skin = buttonSkins[base]
  if skin then return skin end

  skin = makeSkin(string.format("mpButton%06x", base), {
    fill    = colorString(base),
    hover   = shade(base, HOVER_SHIFT),
    pressed = shade(base, PRESSED_SHIFT),
    fg      = textOn(base),
    centred = true, padX = M.padX,
  })
  buttonSkins[base] = skin
  return skin
end

-- pcall here is Lua-side only: a malformed skin table is a table error with a
-- working fallback, not protection against a bad native argument.
local function applySkinTable(widget, skin)
  if FALLBACK_SKINS or not skin then return end
  local ok = pcall(function() widget:setSkin(skin) end)
  if not ok then
    FALLBACK_SKINS = true
    logW("DCS rejected our skin table, so the panel will use default widget skins and " ..
      "the configured colours will not apply. (WidgetSetSkin errored.)")
  end
end

-- Applies one of the named skins from `skins`. Silent if skinning has already been
-- abandoned.
local function applySkin(widget, kind)
  applySkinTable(widget, skins[kind])
end


-- ============================================================ our panel

-- builtEntry is the mission entry currently constructed; a mismatch against activeEntry
-- means the panel belongs to a previous mission. width is the first dialog's measured
-- width, with bodyPanel's shipped 274 standing in until one is seen.
--
-- In strip mode `content` is a viewport and `strip` a wider panel inside it holding
-- every button, so scrolling moves one widget. measured on 2.9.29.27278: panels clip
-- their children to their own bounds, at both edges -- which is what crops the strip
-- without anything being hidden by hand.
local ui = { built = false, visible = false, laidOut = false,
             window = nil, content = nil, strip = nil, builtEntry = nil,
             height = 0, width = 274,
             mode = "rows", scrollX = 0, scrollMax = 0, wheelFn = nil }

-- observed: a widget under about 1px still draws, as a stray line across the screen,
-- so degenerate bounds are refused and the widget hidden instead.
local function setBoundsSafe(widget, x, y, w, h, what)
  if type(w) ~= "number" or type(h) ~= "number" or w < 2 or h < 2 then
    logW("Refusing to size %s to %sx%s and hiding it instead -- a widget under about " ..
      "1px still draws, as a stray line across the screen",
      tostring(what), tostring(w), tostring(h))
    widget:setVisible(false)
    return false
  end
  widget:setBounds(math.floor(x), math.floor(y), math.floor(w), math.floor(h))
  return true
end

-- measured: WidgetCalcSize on a Button returns TEXT width only, excluding the skin's
-- textOffset -- 32 for the five-character "Basic" at font size 11. Padding is added
-- here, and the floor and ceiling both apply to the padded result; testing the raw
-- measurement against the floor discarded every label under about seven characters.
--
-- The fallback estimate is 0.58 of the font size per glyph, an eyeball fit for
-- DejaVuLGCSans, and linear, so it cannot tell "IIII" from "WWWW".
local calcSizeLogged = false
local function buttonWidth(btn, text, inner)
  local est = math.floor(charCount(text) * cfg.fontSize * 0.58) + M.padX * 2
  local ok, w = pcall(function() local a = btn:calcSize() return a end)

  if not calcSizeLogged then
    calcSizeLogged = true
    logD("WidgetCalcSize on a Button: %s (%s) for %q; glyph estimate %d",
      tostring(ok and w), type(ok and w), text, est)
  end

  local width = est
  if ok and type(w) == "number" and w > 0 then
    local padded = w + M.padX * 2
    if padded <= ui.width then width = padded end
  end
  -- Clamped once, here: both bounds belong to the measurement, not to the drawing.
  return math.max(math.min(width, inner), M.minW)
end

-- Set by a button's callback, acted on in onSimulationFrame: keeps handle work in one
-- place and the callback trivial.
local pendingText = nil

-- Returns the window's inner view size, or nil if it cannot be read or reads as
-- degenerate.
local function viewSize(win)
  local _, _, w, h = win:getViewBounds()
  if type(w) == "number" and w > 0 and type(h) == "number" and h > 0 then
    return w, h
  end
  return nil
end

-- Grows the window until its inner view is contentW x contentH and sizes the content
-- panel to match. Mutates ui.window and ui.content.
local function fitWindow(contentW, contentH)
  local win = ui.window
  win:setSize(contentW, contentH)

  local vw, vh = viewSize(win)
  if not vw then
    ui.content:setBounds(0, 0, contentW, contentH)
    return
  end

  -- Content lives in a WindowView inset from the frame, so the window is grown by the
  -- inset to make the view the size asked for.
  local dw, dh = contentW - vw, contentH - vh
  if dw ~= 0 or dh ~= 0 then
    win:setSize(contentW + dw, contentH + dh)
    -- Fresh locals: keeping the pre-resize numbers on a failed read would size the
    -- content panel wrong.
    local nw, nh = viewSize(win)
    if nw then vw, vh = nw, nh end
  end

  ui.content:setBounds(0, 0, vw, vh)
end

-- The active entry's widgets, built on first use and kept for that mission. Only the
-- group in use is ever constructed.
--
-- built = { { header = widget|nil, buttons = { {w=widget, bw=number, fn=function} } } }
local built = {}

-- Creates the window, the content panel and the entry's widgets. A no-op once built,
-- so the width is captured from the first dialog seen in this mission.
local function build(dialogWidth)
  if ui.built then return true end
  if not activeEntry then return false end

  local entry = cfg.profiles[activeEntry]
  if not entry then return false end

  -- Geometry is decided once, here, for the whole panel.
  M = cfg.compact and METRICS.compact or METRICS.normal
  ui.mode = entry.layout or "rows"
  ui.scrollX, ui.scrollMax = 0, 0

  -- As wide as the visible dialog, falling back to bodyPanel's shipped 274.
  ui.width = (type(dialogWidth) == "number" and dialogWidth > 40) and dialogWidth or 274

  buildSkins()

  -- Window.new(..., text) renders that text in the body with the title bar hidden.
  local win = Window.new(0, 0, ui.width, 40, "")
  ui.window = win
  win:setVisible(false)
  win:setDraggable(false)
  win:setResizable(false)
  applySkin(win, "window")
  -- After applySkin: setTitleHeight mutates the current skin, so ours would undo it.
  win:setTitleHeight(0)

  -- UNVERIFIED sign convention: map surface is -1000 and MarkPanel is -600, so
  -- larger appears to draw later. -599 puts us just above the dialog.
  win:setZOrder(-599)

  local content = Panel.new()
  ui.content = content
  applySkin(content, "panel")
  win:insertWidget(content)

  -- The strip is as wide as its contents need; the content panel crops it.
  local host = content
  if ui.mode == "strip" then
    local strip = Panel.new()
    ui.strip = strip
    -- Unskinned: the panel behind carries the background, and a second fill would
    -- double the tint.
    content:insertWidget(strip)
    host = strip
  end

  local inner = ui.width - M.pad * 2
  local total = 0

  for _, section in ipairs(entry.sections) do
    local rec = { buttons = {} }

    if section.header and ui.mode ~= "strip" then
      local st = Static.new(section.header)
      applySkin(st, "header")
      st:setVisible(false)
      host:insertWidget(st)
      rec.header = st
    end

    for _, preset in ipairs(section.presets) do
      local text = preset.text
      local btn = Button.new(preset.name)
      applySkinTable(btn, buttonSkin(preset.buttonColor))
      btn:setVisible(false)
      btn:setTooltipText(text)

      -- Kept: Widget.addChangeCallback stores its wrapper in the module-wide
      -- Widget.callbacks keyed by this function, and only removeChangeCallback clears
      -- it. Holding the value is what lets teardown reclaim it.
      local fn = function()
        logI('Preset "%s" clicked', oneLine(preset.name))
        pendingText = preset
      end
      btn:addChangeCallback(fn)

      host:insertWidget(btn)
      rec.buttons[#rec.buttons + 1] = {
        w = btn, fn = fn,
        bw = buttonWidth(btn, preset.name,
               ui.mode == "strip" and math.huge or inner),
      }
      total = total + 1
    end

    built[#built + 1] = rec
  end

  ui.built = true
  ui.builtEntry = activeEntry
  logI("Panel built: %d button%s from preset group %d, %d px wide, %s%s",
    total, plural(total), activeEntry, ui.width, ui.mode,
    (M == METRICS.compact) and " compact" or "")
  return true
end

-- One setPosition however many buttons are on it, which is why they live on a strip.
local function applyScroll()
  if not ui.strip then return end
  pcall(function() ui.strip:setPosition(M.pad - ui.scrollX, M.pad) end)
end

-- One notch per wheel click, clamped to the strip's travel.
local function scrollBy(clicks)
  if ui.scrollMax <= 0 then return end
  local step = rowH() * 2
  local dir = (type(clicks) == "number" and clicks < 0) and 1 or -1
  local want = math.max(0, math.min(ui.scrollMax, ui.scrollX + step * dir))
  if want ~= ui.scrollX then
    ui.scrollX = want
    applyScroll()
  end
end

-- One row, section order; returns its width. Headers are not built in this mode.
local function layoutStrip(rh)
  local x = 0
  for _, rec in ipairs(built) do
    for _, b in ipairs(rec.buttons) do
      if setBoundsSafe(b.w, x, 0, b.bw, rh, "button") then
        b.w:setVisible(true)
      end
      x = x + b.bw + M.gap
    end
  end
  return math.max(0, x - M.gap)
end

-- Positions the built widgets and resizes the window to fit. Mutates ui.height and
-- the window, and makes every viable widget visible.
local function layout()
  local inner = ui.width - M.pad * 2

  if ui.mode == "strip" then
    local rh = rowH()
    local total = layoutStrip(rh)
    ui.strip:setBounds(M.pad, M.pad, math.max(total, 1), rh)
    ui.strip:setVisible(true)
    ui.height = rh + M.pad * 2
    ui.scrollMax = math.max(0, total - inner)
    ui.scrollX = math.min(ui.scrollX, ui.scrollMax)
    applyScroll()

    -- Here rather than at build: attached once, to a panel that exists, and only when
    -- there is something to scroll.
    if ui.scrollMax > 0 and not ui.wheelFn then
      ui.wheelFn = function(_, _, clicks) scrollBy(clicks) end
      local ok = pcall(dxgui.WidgetAddMouseWheelCallback, ui.content.widget, ui.wheelFn)
      if not ok then
        ui.wheelFn = nil
        logW("Could not attach the wheel handler, so the strip cannot be scrolled and " ..
          "presets past %d px are unreachable. (WidgetAddMouseWheelCallback.)", inner)
      end
    end

    fitWindow(ui.width, ui.height)

    -- measured: a newly parented widget does not draw until its parent recomputes --
    -- correct coordinates and a true visibility flag, and still invisible, until
    -- WidgetUpdateSize reached it. The rows path gets that from fitWindow's setSize;
    -- the strip is a level deeper, so it asks explicitly.
    pcall(dxgui.WidgetUpdateSize, ui.content.widget)

    ui.laidOut = true
    logD("Laid out preset group %d as a strip: %d px of buttons in %d, %d px to scroll",
      ui.builtEntry, total, inner, ui.scrollMax)
    return
  end
  local hh    = rowH()
  local rh    = rowH()
  local y     = M.pad

  for si, rec in ipairs(built) do
    if si > 1 then y = y + M.sectionGap end

    -- Same x and width as the buttons, so the label's left edge lines up.
    if rec.header then
      if setBoundsSafe(rec.header, M.pad, y, inner, hh, "header") then
        rec.header:setVisible(true)
      end
      y = y + hh + 2
    end

    local x = M.pad
    for _, b in ipairs(rec.buttons) do
      if x > M.pad and (x + b.bw) > (M.pad + inner) then
        x = M.pad
        y = y + rh + M.gap
      end
      if setBoundsSafe(b.w, x, y, b.bw, rh, "button") then
        b.w:setVisible(true)
      end
      x = x + b.bw + M.gap
    end
    y = y + rh
  end

  ui.height = y + M.pad
  fitWindow(ui.width, ui.height)
  ui.laidOut = true
  logD("Laid out preset group %d: %d px tall", ui.builtEntry, ui.height)
end

local lastX, lastY = nil, nil
local flipLogged = false

-- ax is the dialog's left edge, ay its bottom, atop its visible top. Horizontal
-- position is never adjusted: the panel stays on the dialog's left edge even if that
-- runs it off screen.
local function place(ax, ay, atop)
  local x, y = ax, ay

  if (y + ui.height) > screenH then
    -- The panel's BOTTOM meets the dialog's TOP. Anchoring its top to the dialog's
    -- bottom instead stacks the two whenever the panel is taller, and our own window
    -- then answers the hit tests -- isOurs skips it, nothing resolves, and the panel
    -- hides itself a moment after appearing.
    local flipped = (atop or ay) - ui.height
    if flipped >= 0 then
      y = flipped
      if not flipLogged then
        logD("No room below the dialog; placing the panel above it")
        flipLogged = true
      end
    else
      -- Fits neither way: stay below and clip, because overlapping the dialog is
      -- self-occlusion rather than a cosmetic compromise.
      if not flipLogged then
        logW("The panel fits neither below nor above the dialog, so it is placed below " ..
          "and clipped at the screen edge. It is %d px tall against a %d px screen.",
          ui.height, screenH)
        flipLogged = true
      end
    end
  else
    flipLogged = false
  end

  x, y = math.floor(x), math.floor(y)
  -- setPosition appears to redraw whether or not the value changed, so a panel that
  -- has not moved is not told to.
  if x ~= lastX or y ~= lastY then
    ui.window:setPosition(x, y)
    lastX, lastY = x, y
  end
end

-- Builds and lays out on first use, positions the panel against the dialog, and
-- makes it visible. Mutates ui.
local function show(ax, ay, aw, atop)
  if not build(aw) then return end
  if not ui.laidOut then layout() end
  place(ax, ay, atop)
  if not ui.visible then
    ui.window:setVisible(true)
    ui.visible = true
  end
end

-- Drops references only. Widget.construct registers every widget in Widget.widgets, a
-- strong table, so nothing is freed until destroyUI destroys it.
local function resetUI()
  ui.window, ui.content, ui.strip = nil, nil, nil
  ui.built, ui.visible, ui.laidOut = false, false, false
  ui.builtEntry, ui.height = nil, 0
  ui.mode, ui.scrollX, ui.scrollMax, ui.wheelFn = "rows", 0, 0, nil
  built = {}
  lastX, lastY = nil, nil
end

-- Destroys the panel's widgets. Safe when nothing is built.
--
-- Change callbacks come off first: Widget.destroy does not touch Widget.callbacks, so
-- only removeChangeCallback keeps that table from growing per button per mission.
--
-- Then leaf to root. Widget.destroy makes one WidgetDestroy call and never walks
-- children, so destroying a parent first may free its children C-side and leave the
-- per-child calls dereferencing freed pointers.
--
-- Widget.destroy clears Widget.widgets, so isOurs cannot be fooled by a freed handle.
local function destroyUI()
  if not ui.built then return end

  -- Unconditionally, and before anything else. A widget-level wheel callback eats the
  -- wheel wherever its widget is, so one left on an abandoned panel leaves a patch of
  -- map that will not zoom -- invisible, unlike a stray widget.
  if ui.wheelFn and ui.content then
    local ok = pcall(dxgui.WidgetRemoveMouseWheelCallback, ui.content.widget, ui.wheelFn)
    if not ok then
      logW("Could not remove the strip's wheel handler, so the area it covered may " ..
        "keep swallowing the wheel until DCS restarts.")
    end
    ui.wheelFn = nil
  end

  local n = 0
  local ran = probe("teardown", function()
    for _, rec in ipairs(built) do
      for _, b in ipairs(rec.buttons) do
        if b.fn then b.w:removeChangeCallback(b.fn) end
        b.w:destroy()
        n = n + 1
      end
      if rec.header then rec.header:destroy() n = n + 1 end
    end
    if ui.strip then ui.strip:destroy() n = n + 1 end
    if ui.content then ui.content:destroy() n = n + 1 end
    if ui.window then ui.window:destroy() n = n + 1 end
  end)

  if ran == nil then
    -- Cannot free them, so at least stop them drawing and taking clicks: an abandoned
    -- window is hit-tested across its whole rect. Reached from the stale-panel
    -- rebuild, which does not hide first.
    if ui.window then ui.window:setVisible(false) end
    logW("Abandoning the previous mission's widgets without destroying them, because " ..
      "teardown is disabled. They are hidden, so they no longer take clicks, but they " ..
      "are not freed.")
  elseif ran == false then
    logW("Teardown raised partway through, so some of the previous panel's widgets " ..
      "were not destroyed. %d of them were.", n)
  else
    logD("Destroyed %d widget%s from the previous panel", n, plural(n))
  end

  resetUI()
end

-- Hides the panel, leaving it built. Mutates ui.
local function hide()
  if ui.window and ui.visible then
    ui.window:setVisible(false)
  end
  ui.visible = false
end

-- ============================================================ writing

-- Caret `target` characters in, or at the end when nil. Selection indices are 0-based
-- and per DISPLAY line, so walking the line lengths is what turns one offset into the
-- pair DCS wants; the measurements are at the call site.
local function setCaret(edit, target, strict)
  local okN, n = pcall(dxgui.EditBoxGetLineCount, edit)
  if not okN or type(n) ~= "number" or n <= 0 then return false end

  if target then
    local acc = 0
    for i = 0, n - 1 do
      local okL, len = pcall(dxgui.EditBoxGetLineTextLength, edit, i)
      if not okL or type(len) ~= "number" then break end
      -- On a soft wrap a boundary offset belongs at this line's end; after a hard
      -- newline it belongs at the next line's start, so it steps past instead.
      local here
      if strict then here = (acc + len) > target else here = (acc + len) >= target end
      if here then
        local col = target - acc
        return (pcall(dxgui.EditBoxSetSelection, edit, i, col, i, col)) and true or false
      end
      acc = acc + len
    end
  end

  -- No marker, or an offset past the end: the end of the last line.
  local last = n - 1
  local okL, len = pcall(dxgui.EditBoxGetLineTextLength, edit, last)
  if okL and type(len) == "number" then
    return (pcall(dxgui.EditBoxSetSelection, edit, last, len, last, len)) and true or false
  end
  return false
end

-- Writes a preset into the tracked mark and sizes the dialog to it. Mutates the
-- DCS-owned dialog only. Every field comes from `tracked`, so there is no second source
-- for the edit box to keep in step.
--
-- The order is measured, against a mark-change counter in the mission scripting state:
--
--   1. focus the edit box, BEFORE the write. Nothing sends here; what it does is leave
--      DCS's idea of "what this field held" as the OLD text, so the user's later
--      defocus sees a difference and sends. Focusing after the write makes those equal
--      and nothing ever sends -- seven preset clicks produced no event at all.
--   2. write. WidgetSetText never sends, across dozens of writes.
--   3. place the caret. Setting a selection never sends either.
--   4. size the dialog. WidgetSetText stores the string without relaying out the
--      field, and WidgetUpdateSize and WidgetRedraw do not help.
--   5. autoCommit only: hide the root and show it again in the same frame. Hiding is
--      the only call that sends outright; showing puts the dialog back, so nothing
--      about its behaviour changes.
--
-- Step 5 is the whole difference between the modes. Off: a preset click produced no
-- event, and the next click on the map exactly one, carrying that text and mark id --
-- the same interaction as typing by hand. On: one event on the click, and nothing
-- further on the click away, the field then matching what was sent.
--
-- Browsing presets does NOT send one per click. DCS sends on a defocus only when the
-- text differs from what was last sent, so a preset restoring already-sent text is
-- silent: five clicks across two presets and two clicks away produced two events.
--
-- A 250-character six-line write preceded a crash; five-line writes do not. The cause
-- is unidentified, so presets are checked against that limit at load.
local function applyText(preset)
  local edit = tracked.edit
  local text, autoCommit = preset.text, preset.autoCommit
  local caretAt, caretStrict = preset.caretAt, preset.caretStrict

  -- A preset replaces the whole field, so this is the only record of what was there.
  logBoxText(edit, "Replacing %d character%s in the text box: %s")

  -- BEFORE the write, and only before: see the ordering above.
  pcall(dxgui.WidgetSetFocused, edit, true)

  if not pcall(dxgui.WidgetSetText, edit, text) then
    logE("Could not write the preset into the mark dialog. (WidgetSetText errored on " ..
      "eMarkLable.)")
    return
  end

  logI("Wrote to mark %s: %s", tostring(tracked.markId), oneLine(text))

  -- Without a marker the caret goes to the end, so typing continues the preset.
  --
  -- measured, and why this is arithmetic rather than one call: EditBoxGetLineCount
  -- returns DISPLAY lines -- 100 characters in the 274px box came back as 3 -- and the
  -- engine refuses a flat index, returning 0,0,0,0 for (0,45) on a three-line field.
  -- But wrapping consumes no characters (72 split into 44 and 28) and a newline is a
  -- separator rather than a character, so walking the line lengths converts exactly.
  if not setCaret(edit, caretAt, caretStrict) and caretAt then
    logW("Could not place the caret %d character(s) in, so it is wherever DCS left it.",
      caretAt)
  end

  -- measured: nothing else resizes the dialog. WidgetUpdateSize on the edit box, the
  -- body panel and the root all left a four-line write at the one-line height; only an
  -- explicit WidgetSetSize moved it. WidgetCalcSize on the EDIT BOX gives the content
  -- height, and the window is that plus the chrome measured at acquisition.
  if tracked.chrome then
    local ch = contentHeight(edit)
    local _, _, w = windowRect(tracked.root)
    if ch and w then
      local wanted = ch + tracked.chrome
      pcall(dxgui.WidgetSetSize, tracked.root, w, wanted)
      logD("Sized the dialog to %dx%d (content %d + chrome %d)",
        w, wanted, ch, tracked.chrome)
    end
  end

  -- So a silent truncation reads as one rather than as a bad preset.
  local stored = textOf(edit)
  if not stored then
    logW("Could not read the text back, so a truncation would go unnoticed. " ..
      "(WidgetGetText on eMarkLable returned nothing usable.)")
  elseif #stored < #text then
    logW("The dialog kept %d of %d bytes, so DCS truncated the text. Kept: %s",
      #stored, #text, oneLine(stored))
  else
    logD("Read back %d byte%s after writing %d", #stored, plural(#stored), #text)
  end

  if not autoCommit then
    -- Left focused holding the new text, with DCS still remembering the old, so the
    -- user's next click outside the box sends it.
    logD("Left for the user to send: click outside the text box to commit mark %s",
      tostring(tracked.markId))
    return
  end

  -- One frame: the hide sends, the show puts it back before anything is drawn.
  if not pcall(dxgui.WidgetSetVisible, tracked.root, false) then
    logW("Could not send the mark. (WidgetSetVisible on its root window.)")
    return
  end
  pcall(dxgui.WidgetSetVisible, tracked.root, true)

  logI("Sent mark %s", tostring(tracked.markId))
end

-- ============================================================ mouse

local pendingClick = nil   -- { x, y, at, tries, seen }
local downPos = nil

-- The reason the panel should be dismissed, or false. A boolean here made two
-- different gestures read identically in the log.
local hideRequested = false

-- Zooming moves the dialog with no button held, so nothing else notices.
local function onMouseWheel(x, y, clicks)
  if not enabled or not tracked then return end
  if not refreshSlot(os.clock()) then return end
  replaceRequested = true
end

-- Dismissal is decided on the RELEASE: a press alone cannot tell a click from the
-- start of a pan, and a pan has to keep the panel, which travels with the dialog.
local function onMouseDown(x, y, button)
  if not enabled then return end
  if not refreshSlot(os.clock()) then return end
  downPos = { x = x, y = y }
end

-- What a completed gesture meant. The panel belongs to the text box being edited, so
-- a press outside eMarkLable dismisses it -- the exact inverse of acquireAt's `edited`
-- rule, testing the same rectangle that summons it. That includes the dialog's own
-- header: the alternative treats the 306x75 window as staying put, and most of that is
-- invisible margin.
--
--   on our own panel   nothing -- pressing a preset must not dismiss the thing
--                      carrying it, nor retarget tracking mid-click
--   a drag             a pan. Keep the panel; the poll follows the dialog
--   into the text box  the user is working in the tracked mark. Keep the panel
--   anywhere else      dismiss, and look for whatever the click landed on: it may
--                      have created a mark or opened another one
local function onMouseUp(x, y, button)
  if not enabled then return end
  if not refreshSlot(os.clock()) then return end
  if not downPos then return end
  local dx, dy = x - downPos.x, y - downPos.y
  downPos = nil

  -- A drag, not a click. Tested first because it costs nothing, and a pan is what
  -- would otherwise pay for the checks below.
  if (dx * dx + dy * dy) > (CLICK_DRAG_THRESHOLD_PX ^ 2) then return end

  -- Pressing a preset must neither dismiss the panel nor retarget tracking.
  if isOurs(rootAt(x, y)) then return end

  -- Inside the tracked text box changes nothing, and skips acquisition: two native
  -- calls on a held handle against the retry ladder's hit tests and name lookups.
  if tracked then
    local ex, ey, ew, eh = screenRect(tracked.edit)
    if ex and x >= ex and x < ex + ew and y >= ey and y < ey + eh then return end
    hideRequested = "clicked outside the text box"
  end

  pendingClick = { x = x, y = y, at = nil, tries = 0 }
end

-- Global callbacks: they fire over our own windows too, hence the isOurs filters.
local function registerMouse()
  local G = (type(_G.Gui) == "table" and _G.Gui.AddMouseCallback) and _G.Gui or dxgui
  if type(G.AddMouseCallback) ~= "function" then
    logE("No AddMouseCallback in either Gui or dxgui, so MarkPresets cannot detect " ..
      "clicks and will do nothing.")
    return
  end
  local ok1 = pcall(G.AddMouseCallback, "down",  onMouseDown)
  local ok2 = pcall(G.AddMouseCallback, "up",    onMouseUp)
  local ok3 = pcall(G.AddMouseCallback, "wheel", onMouseWheel)

  if ok1 and ok2 and ok3 then
    logD("Mouse hooks installed (down, up, wheel)")
  else
    logW("Some mouse hooks were refused: down=%s up=%s wheel=%s. Without down and up " ..
      "the panel cannot appear; without wheel it will trail the dialog when the map " ..
      "is zoomed.", tostring(ok1), tostring(ok2), tostring(ok3))
  end
end

-- ============================================================ callbacks

local MarkPresets = {}

-- Rung 0 is 0.0 so a click into an open dialog retargets in the same frame. The later
-- rungs exist for a click that CREATED a dialog, which does not exist yet on rung 0.
local RETRY_AT = { 0.0, 0.10, 0.30, 0.60 }
local degradedLogged = false

-- A freshly created dialog is not laid out on the frame it is found: it still carries
-- MarkPanel.dlg's 274x127 at 24,59 inside 306x198, which anchors the panel ~24px right
-- and ~110px low of where it belongs once DCS resizes it to 306x75. So the first show
-- waits for two agreeing placements, polling fast until then.
local placedRect = nil
local stableCount = 0
local settled = false

-- Moves the panel inside the dialog's own callback, in the frame the dialog moved.
--
-- measured: one pan fired 181 position events, the dialog moving a mean of 50 px and a
-- maximum of 171 px between consecutive ones. That maximum is how far behind the panel
-- sits when it waits for the next frame, and it is the whole of the visible lag.
-- Repositioning here measured zero drift across all 181 -- the same as parenting the
-- panel to the dialog, which costs a permanent fight over the dialog's height.
--
-- Nothing here creates, destroys or re-resolves a widget: the panel must already be
-- built, laid out, settled and visible, or the flag is set and onSimulationFrame does
-- it in the usual order. That restriction is what makes this safe inside a callback.
repositionNow = function()
  if not (tracked and ui.built and ui.laidOut and ui.visible and settled and screenH) then
    replaceRequested = true
    return
  end
  local px, py, _, pt = anchorOf(tracked.root)
  if not px then
    replaceRequested = true
    return
  end
  place(px, py, pt)
end

-- Clears the per-dialog placement state, so the next one settles from scratch and its
-- one-per-dialog messages log again.
local function resetSettle()
  settleStarted = nil
  placedRect, stableCount, settled = nil, 0, false
  degradedLogged = false
  -- Or the flip and clipped-panel messages log once a session, not once a dialog.
  flipLogged = false
end

-- Stops tracking the current dialog: takes our callbacks back off it, drops its handles,
-- clears the panel state and hides the panel.
--
-- Removal is worth doing. A callback left on a dialog we are no longer watching still
-- fires, still sets replaceRequested, and still costs a closure nothing reclaims --
-- WidgetAddCallback appends, and these are raw calls, so nothing else drops them.
-- Registration is keyed by mark id, so clearing that entry lets the same dialog be
-- re-acquired and re-registered cleanly.
--
-- `keepCallbacks` drops the handles without touching the widgets. Used only as the
-- fallback when removal at mission end has been blacklisted after a crash -- see
-- onSimulationStop.
local function detach(why, keepCallbacks)
  if not tracked then return end

  if tracked.callbacks and not keepCallbacks then
    for _, c in ipairs(tracked.callbacks) do
      local ok = pcall(dxgui.WidgetRemoveCallback, tracked.root, c.kind, c.fn)
      if not ok then
        logW("Could not remove the %q callback from mark %s, so it stays registered " ..
          "for this session. (WidgetRemoveCallback on its root window.)",
          c.kind, tostring(tracked.markId))
      end
    end
    registeredMarks[tracked.markId] = nil
  end

  if why then logD("Dropped mark %s: %s", tostring(tracked.markId), why) end

  tracked = nil
  replaceRequested = false
  resetSettle()
  hide()
end

-- Advances the retry ladder for a click, and adopts the dialog it finds. The ladder
-- exists because the dialog a click creates does not exist on the frame the click is
-- processed.
local function servicePendingClick(now)
  local pc = pendingClick
  if not pc then return end
  if not pc.at then pc.at = now end

  local wait = RETRY_AT[pc.tries + 1]
  if not wait then pendingClick = nil return end
  if (now - pc.at) < wait then return end

  pc.tries = pc.tries + 1

  pc.seen = pc.seen or {}
  local root, id, w = acquireAt(pc.x, pc.y, pc.seen, pc.tries)
  if not root then return end

  pendingClick = nil

  local x, y, ww, h = windowRect(root)
  if not x then
    logW("Found a mark dialog but could not read its position or size, so the panel " ..
      "cannot be placed. (WidgetGetPosition/WidgetGetSize on its root window.)")
    return
  end

  -- Clicking back into the dialog already being tracked is not a new acquisition.
  -- Resetting the settle state here would put a long-settled panel through
  -- stabilisation again, hiding it for two fast polls for no reason.
  if tracked and id == tracked.markId then return end

  -- A different dialog. Release the current one first: overwriting `tracked` would strand
  -- its callbacks registered and its registeredMarks entry set, so re-acquiring it later
  -- would find it already registered and never register again.
  detach("switching to another mark")

  -- Every widget was resolved during acquisition, so nothing is looked up again here.
  -- These handles are then held: mark dialogs are never destroyed, so they stay valid.
  if not (w.body and w.head) then
    logW("Found mark %s but not its panels, so the widget cannot be placed against it. " ..
      "(bodyPanel/headePanel missing from its subtree.)", tostring(id))
    return
  end

  -- Chrome offset, measured rather than written down: the window's height is the edit
  -- box's text content height plus a fixed amount, so measuring it here means the height
  -- we set after a write follows a font or skin change instead of drifting from it.
  local chrome = nil
  local ch = contentHeight(w.edit)
  if ch and ch < h then chrome = h - ch end

  tracked = {
    root = root, edit = w.edit, body = w.body, head = w.head,
    markId = id, chrome = chrome,
  }
  resetSettle()
  registerDialogCallbacks(id)

  logD("Tracking mark %s at %d,%d (%dx%d), chrome offset %s",
    tostring(id), x, y, ww, h, tostring(chrome))

  -- What the mark already says, at the moment the panel attaches to it. Gated on the
  -- level: another native call on a DCS-owned widget purely for the log.
  logBoxText(w.edit, "Its text box holds %d character%s: %s")
end

function MarkPresets.onSimulationFrame()
  if not enabled then return end

  local now = os.clock()

  -- Nothing runs unless we are in a seat. Leaving one drops the dialog and the panel
  -- with it, so a spectator is never left holding either.
  if not refreshSlot(now) then
    if tracked then detach("left the seat") end
    if ui.visible then hide() end
    return
  end

  -- Widgets built under a previous mission still answer their wrappers but render
  -- nothing. onSimulationStop normally destroys them; this catches a mission change
  -- where that callback never arrived, or where the active preset group changed.
  if ui.built and ui.builtEntry ~= activeEntry then
    logI("The panel belongs to a previous mission, so it is being rebuilt.")
    destroyUI()
  end

  if hideRequested then
    local why = hideRequested
    hideRequested = false

    detach(why)
  end

  -- Acquisition probes and panel placement both need screen bounds, so nothing below
  -- runs until GetScreenSize has answered. Seeding a plausible resolution instead
  -- would bound the first click -- serviced before the first refresh -- against
  -- numbers that are right on one machine and wrong everywhere else.
  if not refreshScreen(now) then return end

  servicePendingClick(now)

  if pendingText then
    local text = pendingText
    pendingText = nil
    -- No resolve() here: the poll below does one, and the write only needs the edit box
    -- handle, which is held. What resolve would add is the visibility check, and a write
    -- into a hidden dialog is caught by the poll on this same frame.
    if tracked and isHandle(tracked.edit) then
      applyText(text)

      -- The write resized the dialog, so the panel has to move with it. Doing this here
      -- rather than waiting for `widget size` means it does not depend on that callback
      -- firing.
      replaceRequested = true
    else
      logW("Nothing written: the mark dialog is no longer there. (%s)",
        oneLine(text.text))
    end
  end

  if not tracked then
    if ui.visible then hide() end
    return
  end

  -- Two different jobs, at two different rates.
  --
  -- POSITION, on triggers rather than a clock.
  --
  --   a callback       widget position or widget size fired. This covers panning and
  --                     zooming on its own: widget position follows the dialog as it
  --                     moves rather than firing once when it appears.
  --   our own write     it resizes the dialog, and setting the size to what it already
  --                     is fires no callback, so this does not rely on one.
  --   the wheel         belt and braces for a zoom, since it costs a boolean.
  --
  -- SETTLING needs the fast path too. A fresh dialog is not laid out on the frame it is
  -- found, so the panel waits for two agreeing placements before showing; at the
  -- visibility interval that is two ticks of delay before it appears at all.
  --
  -- VISIBILITY has no trigger. A mark deleted by mission scripting and the F10 map being
  -- closed both hide the dialog without any mouse event, so this is the one thing that
  -- genuinely needs a clock -- and it can be slow, because a panel lingering a beat after
  -- its mark vanishes costs nothing.
  if not settled then
    settleStarted = settleStarted or now
    if (now - settleStarted) > SETTLE_TIMEOUT then
      settled = true
      logD("Placement did not settle in %.1fs; showing the panel anyway", SETTLE_TIMEOUT)
    end
  end

  local moved = replaceRequested or not settled
  replaceRequested = false

  if not moved and (now - lastCheck) < VISIBILITY_POLL then return end
  lastCheck = now

  local edit, ax, ay, aw, atop = resolve()
  if not isHandle(edit) then
    -- Hidden, not destroyed -- nothing destroys a mark dialog. Dropping it anyway:
    -- re-opening one takes a click on its mark, and that click re-acquires it.
    detach("no longer showing")
  elseif type(ax) ~= "number" then
    -- Resolved the dialog but could not read its geometry, so the panel stays where
    -- it is and the tracked centre stops being refreshed -- tracking will go stale
    -- while the dialog is still on screen. Logged once per spell, not per poll.
    if not degradedLogged then
      logW("Tracking mark %s but cannot read its geometry, so the panel is no longer " ..
        "following it. (WidgetGetPosition/WidgetGetSize on its root window.)",
        tostring(tracked.markId))
      degradedLogged = true
    end
  else
    degradedLogged = false

    if settled then
      show(ax, ay, aw, atop)
    else
      if placedRect and placedRect[1] == ax and placedRect[2] == ay
         and placedRect[3] == aw and placedRect[4] == atop then
        stableCount = stableCount + 1
      else
        stableCount = 0
      end
      placedRect = { ax, ay, aw, atop }
      if stableCount >= 1 then
        settled = true
        show(ax, ay, aw, atop)
      end
    end
  end
end

-- Both are used because either can be the one that fires first depending on how
-- the mission is entered.
function MarkPresets.onMissionLoadEnd()
  evaluateMission()
end

function MarkPresets.onSimulationStart()
  evaluateMission()
end

function MarkPresets.onSimulationStop()
  -- Torn down here rather than at the next mission's first frame: this is the earliest
  -- point the widgets are certainly no longer wanted, and the one at which they are
  -- most likely to still be alive.
  hide()
  destroyUI()
  lastX, lastY = nil, nil
  enabled, activeEntry = false, nil
  -- Take our callbacks off the tracked dialog, as every other detach does. This one is
  -- behind the marker because it is the only detach whose widgets belong to a mission
  -- that is ending, and whether a mark dialog outlives its mission is not established --
  -- everything known about their lifetime was measured within one.
  --
  -- Blacklisted after a crash, the handles are still dropped and only the two closures
  -- per dialog stay registered, which is what this hook did before.
  local ran = probe("callback removal at mission end", function() detach() end)
  if ran == nil then detach(nil, true) end

  registeredMarks = {}

  resetSettle()
  pendingClick = nil
  pendingText = nil
  downPos = nil
  hideRequested = false
  inSlot, lastSlotCheck = false, nil
end

-- ============================================================ load

if ENABLED then
  banner()
  if not logFile then
    -- The banner promises that an empty file means the hook did not load. A file that
    -- could not be opened at all looks the same to the user, so say so where it will be
    -- seen: net.log reaches dcs.log regardless.
    if net and net.log then
      net.log("[MarkPresets] could not open " .. logPath .. " -- running with no log file")
    end
  end
  checkProbeMarker()
  loadConfig()
  DCS.setUserCallbacks(MarkPresets)
  registerMouse()

  logI("Loaded. Waiting for a mission.")
  if net and net.log then
    net.log("[MarkPresets] " .. VERSION .. " loaded")
  end
elseif net and net.log then
  net.log("[MarkPresets] " .. VERSION .. " is present but ENABLED is false -- not loading")
end
