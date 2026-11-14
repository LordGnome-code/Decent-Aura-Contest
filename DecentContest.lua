--[[
    DecentContest
    Transmog contests for World of Warcraft: Forever.

    How a contest works:
      1. Anyone with the addon hosts: picks a theme and opens a lobby (Group or Guild).
      2. Everyone with the addon sees the lobby and joins as a Judge or a Contestant.
      3. Host starts the contest. The roster is LOCKED until the contest ends, and
         every client is told who the judges are.
      4. Each judge rates every contestant 1-10 on Theme & Cohesion, Color
         Coordination and Creativity (slider or typed number), then submits.
      5. When every judge has submitted (or the host ends judging early) the host
         totals all judges' scores. Highest overall total wins; equal totals share the win.

    Networking is host-authoritative: clients send requests (join, scores) and the
    host broadcasts the official state (roster, start, results) with hidden addon
    messages. Players are identified by GUID, and the sender name of each message
    is checked against the name it joined with (WoW Forever two-part names are
    matched on either "First" or "First Second").
]]

local ADDON_NAME = ...
local DC = CreateFrame("Frame", "DecentContestCore")

local PREFIX      = "DecentContest"   -- addon message prefix (max 16 chars)
local PROTOCOL    = 1
local COLOR       = "|cffa070ff"
local MAX_THEME   = 80
local PAYLOAD_MAX = 180               -- packed entries per addon message (limit is 255 total)
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local CRITERIA = {
    { key = "t", label = "Theme & Cohesion",   short = "Theme" },
    { key = "c", label = "Color Coordination", short = "Color" },
    { key = "r", label = "Creativity",         short = "Creativity" },
}
local MAX_PER_JUDGE = 10 * #CRITERIA

local DEFAULTS = {
    channel     = "GROUP",   -- GROUP | GUILD (for contests you host)
    lastTheme   = "",
    announce    = true,      -- host posts open/start/winner in group or guild chat
    popup       = true,      -- open the window when someone opens a contest
    showOnLogin = false,
    scale       = 1.0,
    blizzardUI  = false,
    locked      = false,
    minimap     = true,
    minimapAngle = 200,
    maxHistory  = 50,
    pos         = nil,
}

local DB, S
local UI = {}
local settingsFrame, minimapButton
local H                      -- host state (only while you are hosting), saved in DB.host
local game                   -- what this client knows about the current contest
local draft                  -- this judge's scores for the current contest, saved in DB.drafts
local Refresh, Broadcast, HandleMessage

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(COLOR .. "DecentContest|r: " .. tostring(msg))
end

local function ShortName(n)
    if not n or n == "" then return nil end
    if Ambiguate then n = Ambiguate(n, "short") end
    n = n:gsub("%-[^%s]+$", "")          -- strip "-Realm"
    n = strtrim(n):gsub("%s+", " ")
    return n ~= "" and n or nil
end

local function FirstName(n) return n and n:match("^(%S+)") end

-- "Kael" and "Kael Sunstrider" are the same person (WoW Forever two-part names).
local function NamesMatch(a, b)
    if not a or not b then return false end
    a, b = a:lower(), b:lower()
    if a == b then return true end
    if a:find(" ", 1, true) and b:find(" ", 1, true) then return false end
    return FirstName(a) == FirstName(b)
end

local function MyName() return ShortName(UnitName("player")) or "?" end
local function MyGUID() return UnitGUID("player") end

-- Strip characters used by the message format and chat escape codes.
local function CleanName(s)  return (s or ""):gsub("[~;,|]", "") end
local function CleanTheme(s)
    s = strtrim((s or ""):gsub("[~|]", ""):gsub("%s+", " "))
    if #s > MAX_THEME then s = s:sub(1, MAX_THEME) end
    return s
end

local function Split(s, sep)
    local t, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then t[#t + 1] = s:sub(start); return t end
        t[#t + 1] = s:sub(start, i - 1)
        start = i + 1
    end
end

local function JoinNames(list, max)
    max = max or 10
    if #list == 0 then return "none" end
    if #list <= max then return table.concat(list, ", ") end
    local t = {}
    for i = 1, max do t[i] = list[i] end
    return table.concat(t, ", ") .. (" and %d more"):format(#list - max)
end

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

local function SafePlaySound(id)
    if id then pcall(PlaySound, id) end
end

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
        and not (LE_PARTY_CATEGORY_HOME and IsInGroup(LE_PARTY_CATEGORY_HOME)) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end

-- Contest channel key -> live chat type, or nil when it isn't available (solo = local test mode).
local function ResolveChannel(key)
    if key == "GUILD" then return IsInGuild() and "GUILD" or nil end
    return GroupChannel()
end

local CHANNEL_LABEL = { GROUP = "Group", GUILD = "Guild" }

-- Find a unit token for a GUID so we can show a 3D model / inspect.
local function UnitForGUID(guid)
    if not guid then return nil end
    if UnitGUID("player") == guid then return "player" end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            if UnitGUID(u) == guid then return u end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local u = "party" .. i
            if UnitGUID(u) == guid then return u end
        end
    end
    for _, u in ipairs({ "target", "mouseover", "focus" }) do
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
end

---------------------------------------------------------------------------
-- Addon message transport (token bucket so big contests don't get throttled)
---------------------------------------------------------------------------
local queue, tokens, lastRefill = {}, 8, 0
local sentEcho = {}      -- text -> { n = count, t = time } of our own messages, to skip their echo
local pumpTicker
local warnedSendFail = false

local function RawSend(text, chan)
    local fn = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if not fn then return true end
    local ok, r = pcall(fn, PREFIX, text, chan)
    if not ok then return nil end                          -- hard error: drop it
    if r == nil or r == true or r == 0 then return true end
    if Enum and Enum.SendAddonMessageResult and r == Enum.SendAddonMessageResult.Success then return true end
    return false                                           -- throttled / refused: retry later
end

local function Pump()
    local now = GetTime()
    tokens = math.min(8, tokens + (now - lastRefill))
    lastRefill = now
    while #queue > 0 and tokens >= 1 do
        local m = queue[1]
        local chan = ResolveChannel(m.key)
        if not chan then
            table.remove(queue, 1)                         -- solo: handled locally only
        else
            local res = RawSend(m.text, chan)
            if res then
                tokens = tokens - 1
                local e = sentEcho[m.text]
                if not e or now - e.t > 15 then e = { n = 0 }; sentEcho[m.text] = e end
                e.n, e.t = e.n + 1, now
                table.remove(queue, 1)
            else
                m.tries = (m.tries or 0) + 1
                if res == nil or m.tries > 40 then
                    table.remove(queue, 1)
                    if not warnedSendFail then
                        warnedSendFail = true
                        Print("|cffff6060Could not send addon messages.|r Trial/veteran accounts can't send them, and some instances block them.")
                    end
                end
                break
            end
        end
    end
    if #queue == 0 and pumpTicker then pumpTicker:Cancel(); pumpTicker = nil end
end

local function Enqueue(text, key)
    queue[#queue + 1] = { text = text, key = key }
    if not pumpTicker then pumpTicker = C_Timer.NewTicker(0.2, Pump) end
    Pump()
end

-- Send to everyone AND handle it ourselves right away (our own echo is ignored).
function Broadcast(text, key)
    Enqueue(text, key)
    HandleMessage(text, MyName(), true)
end

-- Split a list of entries into payloads that each fit in one message.
local function Pack(entries)
    local packets, cur, len = {}, {}, 0
    for _, e in ipairs(entries) do
        if len + #e + 1 > PAYLOAD_MAX and #cur > 0 then
            packets[#packets + 1] = table.concat(cur, ";")
            cur, len = {}, 0
        end
        cur[#cur + 1] = e
        len = len + #e + 1
    end
    if #cur > 0 or #packets == 0 then packets[#packets + 1] = table.concat(cur, ";") end
    return packets
end

-- Reassemble multi-part messages. Returns the joined payload once every part arrived.
local function Assemble(store, key, part, n, payload)
    if not part or not n or n < 1 or n > 30 or part < 1 or part > n then return nil end
    local a = store[key]
    if not a or a.n ~= n then a = { n = n, got = 0, parts = {} }; store[key] = a end
    if not a.parts[part] then a.parts[part] = payload; a.got = a.got + 1 end
    if a.got == n then
        store[key] = nil
        return table.concat(a.parts, ";")
    end
end

---------------------------------------------------------------------------
-- Client-side contest state
---------------------------------------------------------------------------
local function NewGame()
    return {
        phase = "idle",          -- idle | lobby | judging | results
        roster = {}, judges = {}, contestants = {}, bySlot = {},
        judgeDone = {}, rparts = {}, wparts = {}, rseq = 0,
    }
end
game = NewGame()

local function Announce(text)
    local key = (H and H.chanKey) or game.chanKey
    local chan = S.announce and ResolveChannel(key)
    if chan then
        local msg = "[DecentContest] " .. text
        if #msg > 250 then msg = msg:sub(1, 247) .. "..." end
        if pcall(SendChatMessage, msg, chan) then return end
    end
    Print(text)
end

local function SetRoster(entries)
    game.roster, game.judges, game.contestants, game.bySlot = {}, {}, {}, {}
    game.mySlot, game.myRole = nil, nil
    local me = MyGUID()
    for _, e in ipairs(entries) do
        game.roster[#game.roster + 1] = e
        game.bySlot[e.slot] = e
        if e.role == "J" then game.judges[#game.judges + 1] = e else game.contestants[#game.contestants + 1] = e end
        if e.guid == me then game.mySlot, game.myRole = e.slot, e.role end
    end
    local bySlot = function(a, b) return a.slot < b.slot end
    table.sort(game.judges, bySlot)
    table.sort(game.contestants, bySlot)
end

local function NamesOf(list)
    local t = {}
    for i, e in ipairs(list) do t[i] = e.name end
    return t
end

local function LoadDraft()
    for id in pairs(DB.drafts) do
        if id ~= game.id then DB.drafts[id] = nil end
    end
    DB.drafts[game.id] = DB.drafts[game.id] or { scores = {}, submitted = false }
    draft = DB.drafts[game.id]
end

local function ComputeStandings(totals, nj)
    local list = {}
    for _, e in ipairs(game.contestants) do
        local T = totals[e.slot] or { t = 0, c = 0, r = 0 }
        list[#list + 1] = { name = e.name, slot = e.slot, t = T.t, c = T.c, r = T.r, total = T.t + T.c + T.r }
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    for i, s in ipairs(list) do
        s.rank = (i > 1 and list[i - 1].total == s.total) and list[i - 1].rank or i
        s.avg = nj > 0 and s.total / nj or 0
    end
    return list
end

local function Winners(standings)
    local w = {}
    for _, s in ipairs(standings) do if s.rank == 1 then w[#w + 1] = s end end
    return w
end

-- Remember finished/cancelled contest ids so a late resync can't replay them.
local function MarkFinished(id)
    if not id then return end
    DB.finished[id] = time()
    local n, oldest, oldestId = 0, nil, nil
    for k, t in pairs(DB.finished) do
        n = n + 1
        if not oldest or t < oldest then oldest, oldestId = t, k end
    end
    if n > 30 then DB.finished[oldestId] = nil end
end

local function SaveHistory()
    local standings = {}
    for i, s in ipairs(game.standings) do
        standings[i] = { name = s.name, t = s.t, c = s.c, r = s.r, total = s.total, rank = s.rank }
    end
    table.insert(DB.history, 1, {
        time = time(), theme = game.theme, host = game.host,
        judges = NamesOf(game.judges), judgesCounted = game.judgesCounted, standings = standings,
    })
    while #DB.history > (S.maxHistory or 50) do table.remove(DB.history) end
end

---------------------------------------------------------------------------
-- Host logic
---------------------------------------------------------------------------
local rosterTimer, resyncTimer, lastResync = nil, nil, 0

local function SaveHost() DB.host = H end

local function HostRosterEntries()
    local list = {}
    for _, e in pairs(H.roster) do list[#list + 1] = e end
    table.sort(list, function(a, b) return a.slot < b.slot end)
    return list
end

local function HostCount(role)
    local n = 0
    for _, e in pairs(H.roster) do if e.role == role then n = n + 1 end end
    return n
end

local function BroadcastRoster()
    if rosterTimer then rosterTimer:Cancel(); rosterTimer = nil end
    if not H then return end
    H.rseq = (H.rseq or 0) + 1
    local entries = {}
    for _, e in ipairs(HostRosterEntries()) do
        entries[#entries + 1] = ("%d,%s,%s,%s"):format(e.slot, e.role, e.guid, CleanName(e.name))
    end
    local packets = Pack(entries)
    for i, p in ipairs(packets) do
        Broadcast(("R~%s~%d~%d~%d~%s"):format(H.id, H.rseq, i, #packets, p), H.chanKey)
    end
end

local function ScheduleRoster()
    if rosterTimer then return end
    rosterTimer = C_Timer.NewTimer(0.5, BroadcastRoster)
end

local function BroadcastResults()
    local entries = {}
    for slot, T in pairs(H.results.totals) do
        entries[#entries + 1] = ("%d,%d,%d,%d"):format(slot, T.t, T.c, T.r)
    end
    table.sort(entries)
    H.wseq = (H.wseq or 0) + 1
    local packets = Pack(entries)
    for i, p in ipairs(packets) do
        Broadcast(("W~%s~%d~%d~%d~%d~%s"):format(H.id, H.wseq, i, #packets, H.results.nj, p), H.chanKey)
    end
end

-- Re-send the whole contest so late joiners / reloaded clients catch up.
local function Resync()
    if resyncTimer then resyncTimer:Cancel(); resyncTimer = nil end
    if not H then return end
    lastResync = GetTime()
    Broadcast(("O~%s~%d~%s~%s"):format(H.id, PROTOCOL, H.chanKey, H.theme), H.chanKey)
    BroadcastRoster()
    if H.phase == "judging" or H.phase == "done" then
        Broadcast("G~" .. H.id, H.chanKey)
        for jslot in pairs(H.final) do Broadcast(("P~%s~%d"):format(H.id, jslot), H.chanKey) end
    end
    if H.phase == "done" and H.results then BroadcastResults() end
end

local function ScheduleResync(delay)
    if resyncTimer or not H then return end
    local wait = math.max(delay or 0, 5 - (GetTime() - lastResync))
    resyncTimer = C_Timer.NewTimer(math.max(wait, 0.1), Resync)
end

local function HostOpen(theme)
    theme = CleanTheme(theme)
    if theme == "" then Print("Enter a theme first.") return end
    if H and H.phase ~= "done" then Print("You are already hosting a contest.") return end
    if game.phase == "lobby" or game.phase == "judging" then
        Print("A contest is already running. Wait for it to finish (or /dcon reset).")
        return
    end
    local key = S.channel
    if not ResolveChannel(key) then
        Print(("You're not in a %s, so this contest is |cffffd200local test mode|r: nobody else will see it.")
            :format(key == "GUILD" and "guild" or "group"))
    end
    S.lastTheme = theme
    game = NewGame()
    H = {
        id = tostring(time() % 1000000) .. tostring(math.random(10, 99)),
        chanKey = key, theme = theme, phase = "lobby",
        nextSlot = 1, roster = {}, byGuid = {},
        scores = {}, final = {}, sparts = {},
    }
    SaveHost()
    Broadcast(("O~%s~%d~%s~%s"):format(H.id, PROTOCOL, H.chanKey, H.theme), H.chanKey)
    Announce(("Transmog contest is open! Theme: \"%s\". Get the DecentContest addon and type /dcon to join as a judge or contestant.")
        :format(theme))
end

local function HostStart()
    if not H or H.phase ~= "lobby" then return end
    local nj, nc = HostCount("J"), HostCount("C")
    if nj < 1 or nc < 1 then Print("You need at least 1 judge and 1 contestant to start.") return end
    H.phase = "judging"
    SaveHost()
    BroadcastRoster()                     -- final, locked roster
    Broadcast("G~" .. H.id, H.chanKey)
    local judges, contestants = {}, {}
    for _, e in ipairs(HostRosterEntries()) do
        if e.role == "J" then judges[#judges + 1] = e.name else contestants[#contestants + 1] = e.name end
    end
    Announce(("Contest started! Theme: \"%s\" | Judges: %s | %s competing. Entries are locked.")
        :format(H.theme, JoinNames(judges, 6), Plural(#contestants, "contestant")))
end

local function HostFinalize()
    if not H or H.phase ~= "judging" then return end
    local totals, nj = {}, 0
    for _, e in pairs(H.roster) do
        if e.role == "C" then totals[e.slot] = { t = 0, c = 0, r = 0 } end
    end
    for jslot in pairs(H.final) do
        nj = nj + 1
        for cslot, s in pairs(H.scores[jslot] or {}) do
            local T = totals[cslot]
            if T then T.t, T.c, T.r = T.t + s.t, T.c + s.c, T.r + s.r end
        end
    end
    if nj == 0 then Print("No judge has submitted scores yet. Wait, or cancel the contest.") return end
    H.phase = "done"
    H.results = { totals = totals, nj = nj }
    SaveHost()
    BroadcastResults()
    -- Announce from the standings the client view just computed.
    if game.standings and #game.standings > 0 then
        local w, names = Winners(game.standings), {}
        for i, s in ipairs(w) do names[i] = s.name end
        local verb = #w > 1 and "Tie for first" or "Winner"
        Announce(("%s: %s with %d points (avg %.1f/%d from %s)! Theme was \"%s\".")
            :format(verb, table.concat(names, " & "), w[1].total, w[1].avg, MAX_PER_JUDGE, Plural(nj, "judge"), H.theme))
    end
end

local function HostCancel(silent)
    if not H then return end
    if H.phase ~= "done" then
        Broadcast("C~" .. H.id, H.chanKey)
        if not silent then Announce("The transmog contest was cancelled.") end
    end
    H = nil
    SaveHost()
    if rosterTimer then rosterTimer:Cancel(); rosterTimer = nil end
    if resyncTimer then resyncTimer:Cancel(); resyncTimer = nil end
end

---------------------------------------------------------------------------
-- Message handling
--   Host -> all:  O open, R roster, G go (locked), P judge submitted, W results, C cancel
--   Client -> host: J join/leave, S scores, Q please resync
---------------------------------------------------------------------------
local warnedProtocol = false

local function FromHost(sender, isLocal)
    if isLocal then return game.hostIsMe end
    return NamesMatch(sender, game.host) and not game.hostIsMe
end

local HANDLERS = {}

HANDLERS.O = function(f, sender, isLocal)
    local id, proto, chanKey, theme = f[2], tonumber(f[3]), f[4], CleanTheme(f[5])
    if proto ~= PROTOCOL then
        if not warnedProtocol then
            warnedProtocol = true
            Print(("%s is hosting with a different DecentContest version. Update the addon to take part."):format(sender))
        end
        return
    end
    if game.id == id then
        if FromHost(sender, isLocal) then game.theme = theme; Refresh() end
        return
    end
    if game.phase == "lobby" or game.phase == "judging" then return end  -- busy with another contest
    if H and not isLocal and H.phase ~= "done" then return end             -- we're hosting our own
    if DB.finished[id] then return end                                     -- already saw it end
    game = NewGame()
    game.id, game.theme, game.chanKey, game.phase = id, theme, chanKey, "lobby"
    game.host, game.hostIsMe = sender, isLocal and true or false
    draft = nil
    if not isLocal then
        Print(("%s opened a transmog contest! Theme: |cffffd200%s|r. Type /dcon to join."):format(sender, theme))
        SafePlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK)
    end
    if (S.popup or isLocal) and UI.main then UI.main:Show() end
    Refresh()
end

HANDLERS.R = function(f, sender, isLocal)
    if f[2] ~= game.id or not FromHost(sender, isLocal) or game.locked then return end
    local seq = tonumber(f[3])
    if not seq or seq < game.rseq then return end
    local payload = Assemble(game.rparts, seq, tonumber(f[4]), tonumber(f[5]), f[6] or "")
    if not payload then return end
    game.rseq = seq
    local entries = {}
    for _, item in ipairs(Split(payload, ";")) do
        local slot, role, guid, name = item:match("^(%d+),([JC]),([^,]+),(.+)$")
        if slot then entries[#entries + 1] = { slot = tonumber(slot), role = role, guid = guid, name = name } end
    end
    SetRoster(entries)
    Refresh()
end

HANDLERS.G = function(f, sender, isLocal)
    if f[2] ~= game.id or not FromHost(sender, isLocal) or game.locked then return end
    game.locked, game.phase = true, "judging"
    LoadDraft()
    UI.sel, UI.tabOffset = 1, 0
    Print(("Contest started! Theme: |cffffd200%s|r"):format(game.theme or ""))
    Print(("Judges: |cff80c0ff%s|r"):format(JoinNames(NamesOf(game.judges), 20)))
    Print(("Contestants: %s"):format(JoinNames(NamesOf(game.contestants), 20)))
    if game.myRole == "J" then
        Print("You are a |cff80c0ffjudge|r. Rate every contestant, then press Submit Final Scores.")
    elseif game.myRole == "C" then
        Print("You are a |cffffd200contestant|r. Strike a pose and stay close to the judges!")
    end
    SafePlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK)
    if game.myRole and UI.main then UI.main:Show() end
    Refresh()
end

HANDLERS.P = function(f, sender, isLocal)
    if f[2] ~= game.id or not FromHost(sender, isLocal) then return end
    local jslot = tonumber(f[3])
    if jslot and not game.judgeDone[jslot] then
        game.judgeDone[jslot] = true
        if jslot == game.mySlot and draft then draft.submitted = true end
        Refresh()
    end
end

HANDLERS.W = function(f, sender, isLocal)
    if f[2] ~= game.id or not FromHost(sender, isLocal) or game.phase == "results" then return end
    local nj = tonumber(f[6]) or 0
    local payload = Assemble(game.wparts, tonumber(f[3]) or 0, tonumber(f[4]), tonumber(f[5]), f[7] or "")
    if not payload then return end
    local totals = {}
    for _, item in ipairs(Split(payload, ";")) do
        local slot, t, c, r = item:match("^(%d+),(%d+),(%d+),(%d+)$")
        if slot then totals[tonumber(slot)] = { t = tonumber(t), c = tonumber(c), r = tonumber(r) } end
    end
    game.phase, game.judgesCounted = "results", nj
    game.standings = ComputeStandings(totals, nj)
    UI.resultsOffset = 0
    MarkFinished(game.id)
    SaveHistory()
    if DB.drafts then DB.drafts[game.id] = nil end
    draft = nil
    local w = Winners(game.standings)
    if #w > 0 then
        local names = {}
        for i, s in ipairs(w) do names[i] = s.name end
        Print(("%s |cffffd200%s|r with %d points!"):format(#w > 1 and "Tie for first:" or "Winner:", table.concat(names, " & "), w[1].total))
        for _, s in ipairs(w) do
            if game.bySlot[s.slot] and game.bySlot[s.slot].guid == MyGUID() then
                Print("|cff40ff40Congratulations, you won!|r")
            end
        end
    end
    SafePlaySound(SOUNDKIT and (SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.READY_CHECK))
    if UI.main and game.mySlot then UI.main:Show() end
    Refresh()
end

HANDLERS.C = function(f, sender, isLocal)
    if f[2] ~= game.id or not FromHost(sender, isLocal) then return end
    if not isLocal then Print("The host cancelled the transmog contest.") end
    MarkFinished(game.id)
    if DB.drafts then DB.drafts[game.id] = nil end
    game, draft = NewGame(), nil
    Refresh()
end

-- Client -> host --------------------------------------------------------
HANDLERS.J = function(f, sender)
    if not H or f[2] ~= H.id or H.phase ~= "lobby" then return end   -- locked once started
    local role, guid = f[3], f[4]
    if not guid or guid == "" or (role ~= "J" and role ~= "C" and role ~= "X") then return end
    local slot = H.byGuid[guid]
    if slot then
        local e = H.roster[slot]
        if not e or not NamesMatch(e.name, sender) then return end
        if role == "X" then
            H.roster[slot], H.byGuid[guid] = nil, nil
        else
            e.role = role
        end
    elseif role ~= "X" then
        slot = H.nextSlot
        H.nextSlot = slot + 1
        H.roster[slot] = { slot = slot, role = role, guid = guid, name = CleanName(sender) }
        H.byGuid[guid] = slot
    else
        return
    end
    ScheduleRoster()
end

HANDLERS.S = function(f, sender)
    if not H or f[2] ~= H.id or H.phase ~= "judging" then return end
    local jslot = tonumber(f[3])
    local judge = jslot and H.roster[jslot]
    if not judge or judge.role ~= "J" or not NamesMatch(judge.name, sender) then return end
    if H.final[jslot] then
        Broadcast(("P~%s~%d"):format(H.id, jslot), H.chanKey)       -- they missed the ack
        return
    end
    local payload = Assemble(H.sparts, jslot, tonumber(f[4]), tonumber(f[5]), f[6] or "")
    if not payload then return end
    local scores = {}
    for _, item in ipairs(Split(payload, ";")) do
        local cs, t, c, r = item:match("^(%d+),(%d+),(%d+),(%d+)$")
        cs, t, c, r = tonumber(cs), tonumber(t), tonumber(c), tonumber(r)
        local ce = cs and H.roster[cs]
        if ce and ce.role == "C" and t >= 1 and t <= 10 and c >= 1 and c <= 10 and r >= 1 and r <= 10 then
            scores[cs] = { t = t, c = c, r = r }
        end
    end
    for _, e in pairs(H.roster) do
        if e.role == "C" and not scores[e.slot] then
            Print(("Scores from %s were incomplete and ignored."):format(judge.name))
            return
        end
    end
    H.scores[jslot], H.final[jslot] = scores, true
    Broadcast(("P~%s~%d"):format(H.id, jslot), H.chanKey)
    for _, e in pairs(H.roster) do
        if e.role == "J" and not H.final[e.slot] then return end
    end
    HostFinalize()                                                  -- every judge is in
end

HANDLERS.Q = function()
    if H then ScheduleResync(0.5) end
end

function HandleMessage(text, sender, isLocal)
    local f = Split(text, "~")
    local h = HANDLERS[f[1]]
    if h then h(f, sender, isLocal) end
end

local function OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= PREFIX or not text then return end
    sender = ShortName(sender)
    if not sender then return end
    local e = sentEcho[text]
    if e and e.n > 0 and GetTime() - e.t < 15 and NamesMatch(FirstName(sender), FirstName(MyName())) then
        e.n = e.n - 1                                               -- our own message coming back
        return
    end
    HandleMessage(text, sender, false)
end

local function RequestSync()
    for _, key in ipairs({ "GROUP", "GUILD" }) do
        if ResolveChannel(key) then Enqueue("Q~0", key) end
    end
end

---------------------------------------------------------------------------
-- Player actions
---------------------------------------------------------------------------
local function JoinAs(role)
    if game.phase ~= "lobby" then return end
    Broadcast(("J~%s~%s~%s"):format(game.id, role, MyGUID()), game.chanKey)
    if not game.hostIsMe and not ResolveChannel(game.chanKey) then
        Print("You're no longer in the contest's group/guild, so the host can't hear you.")
    end
end

local function DraftScore(cslot)
    draft.scores[cslot] = draft.scores[cslot] or {}
    return draft.scores[cslot]
end

local function IsScored(cslot)
    local s = draft and draft.scores[cslot]
    return s and s.t and s.c and s.r and true or false
end

local function AllScored()
    if not draft then return false end
    for _, e in ipairs(game.contestants) do
        if not IsScored(e.slot) then return false end
    end
    return #game.contestants > 0
end

local function SubmitScores()
    if game.phase ~= "judging" or game.myRole ~= "J" or not AllScored() then return end
    local entries = {}
    for _, e in ipairs(game.contestants) do
        local s = draft.scores[e.slot]
        entries[#entries + 1] = ("%d,%d,%d,%d"):format(e.slot, s.t, s.c, s.r)
    end
    draft.submitted = true
    draft.sentAt = time()
    local packets = Pack(entries)
    for i, p in ipairs(packets) do
        Broadcast(("S~%s~%d~%d~%d~%s"):format(game.id, game.mySlot, i, #packets, p), game.chanKey)
    end
    Print("Scores submitted. Waiting for the other judges...")
    Refresh()
end

local function Confirm(text, fn)
    StaticPopupDialogs.DECENTCONTEST_CONFIRM = StaticPopupDialogs.DECENTCONTEST_CONFIRM or {
        text = "%s", button1 = YES or "Yes", button2 = NO or "No",
        OnAccept = function(_, data) if data then data() end end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }
    StaticPopup_Show("DECENTCONTEST_CONFIRM", text, nil, fn)
end

local function ClearLocal()
    if H and H.phase == "done" then H = nil; SaveHost() end
    game, draft = NewGame(), nil
    Refresh()
end

---------------------------------------------------------------------------
-- UI building blocks
---------------------------------------------------------------------------
local FRAME_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local BOX_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local FLAT_BACKDROP = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 }
local BLIZZARD_FRAME = {
    bgFile = "Interface\\FrameGeneral\\UI-Background-Marble",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 256, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local BLIZZARD_INSET = {
    bgFile = "Interface\\FrameGeneral\\UI-Background-Rock",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 256, edgeSize = 12,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local themedBoxes = {}

local function Tooltip(owner, title, body)
    owner:EnableMouse(true)
    owner:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, .82, 0)
        local text = type(body) == "function" and body() or body
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return owner
end

local function MakeBox(parent, w, h, title)
    local b = CreateFrame("Frame", nil, parent, BACKDROP_TEMPLATE)
    b:SetSize(w, h)
    b:SetBackdrop(BOX_BACKDROP)
    b:SetBackdropColor(0, 0, 0, 0.55)
    b:SetBackdropBorderColor(0.4, 0.3, 0.6, 1)
    themedBoxes[#themedBoxes + 1] = b
    if title then
        b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.title:SetPoint("TOPLEFT", 10, -8)
        b.title:SetText(title)
    end
    return b
end

local function MakeButton(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(text)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function MakeCheck(parent, text, key, y)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", 14, y)
    check.text = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    check.text:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check.text:SetText(text)
    check:SetChecked(S[key] and true or false)
    check:SetScript("OnClick", function(self)
        S[key] = self:GetChecked() and true or false
        if key == "scale" then
            UI.main:SetScale(S.scale)
        elseif key == "blizzardUI" then
            if UI.applyTheme then UI.applyTheme() end
        elseif key == "minimap" then
            if minimapButton then minimapButton:SetShown(S.minimap) end
        end
    end)
    return check
end

local function SkinFrame(f, inset)
    if not f.SetBackdrop then return end
    if S.blizzardUI then
        f:SetBackdrop(inset and BLIZZARD_INSET or BLIZZARD_FRAME)
        f:SetBackdropColor(1, 1, 1, 1)
        f:SetBackdropBorderColor(1, 1, 1, 1)
    else
        f:SetBackdrop(inset and BOX_BACKDROP or FRAME_BACKDROP)
        f:SetBackdropColor(inset and 0 or .06, inset and 0 or .03, inset and 0 or .10, inset and .55 or .96)
        f:SetBackdropBorderColor(.63, .44, 1, 1)
    end
end

local function ApplyTheme()
    if UI.main then SkinFrame(UI.main, false) end
    if UI.settings then SkinFrame(UI.settings, false) end
    for _, box in ipairs(themedBoxes) do SkinFrame(box, true) end
    if UI.blizzardTabs then
        for _, tab in ipairs(UI.blizzardTabs) do
            if S.blizzardUI then
                tab:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
                tab:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
                tab:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
                tab.text:SetTextColor(1, .82, .1)
            else
                tab:SetNormalTexture(nil); tab:SetPushedTexture(nil); tab:SetHighlightTexture(nil)
                tab.text:SetTextColor(1, 1, 1)
            end
        end
    end
    if UI.main and UI.main:IsShown() and UI.idle then Refresh() end
end

local function ToggleSettings()
    if settingsFrame then settingsFrame:SetShown(not settingsFrame:IsShown()) end
end

local function PositionMinimap()
    if not minimapButton or not Minimap then return end
    local angle = math.rad(S.minimapAngle or 200)
    local radius = Minimap:GetWidth() / 2 + 8
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
    if not Minimap or minimapButton then return end
    local b = CreateFrame("Button", "DecentContestMinimapButton", Minimap)
    minimapButton = b
    b:SetSize(31, 31); b:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21); icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\INV_Chest_Cloth_29")
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53); border:SetPoint("CENTER")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ToggleSettings()
        elseif UI.main then UI.main:SetShown(not UI.main:IsShown()) end
    end)
    b:SetScript("OnDragStart", function(self)
        if S.locked then return end
        self:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local mx, my = Minimap:GetCenter()
            S.minimapAngle = math.deg(math.atan2(y / scale - my, x / scale - mx))
            PositionMinimap()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    Tooltip(b, "DecentContest", "Left-click to open the contest window. Right-click for settings. Drag to move this icon around the minimap.")
    PositionMinimap()
    b:SetShown(S.minimap)
end

local function MakeLabel(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local function MakeEditBox(parent, w, maxLetters, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetAutoFocus(false)
    if maxLetters then e:SetMaxLetters(maxLetters) end
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed", e.ClearFocus)
    return e
end

-- A plain 1-10 slider that doesn't depend on version-specific templates.
local function MakeSlider(parent, w, onChange)
    local s = CreateFrame("Slider", nil, parent, BACKDROP_TEMPLATE)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w, 17)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(1, 10)
    s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:SetValue(5)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        if not self:IsEnabled() then return end
        local v = math.floor(self:GetValue() + 0.5) + (delta > 0 and 1 or -1)
        self:SetValue(math.max(1, math.min(10, v)))
    end)
    s:SetScript("OnValueChanged", function(self, v)
        if self.updating then return end
        onChange(math.floor(v + 0.5))
    end)
    local lo = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lo:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 2, 0); lo:SetText("1")
    local hi = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hi:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", -2, 0); hi:SetText("10")
    function s:SetQuiet(v)
        self.updating = true
        self:SetValue(v)
        self.updating = false
    end
    return s
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local W, HGT = 660, 480

local function SavePos()
    local p, _, rp, x, y = UI.main:GetPoint()
    S.pos = { p, rp, x, y }
end

local function BuildMain()
    local f = CreateFrame("Frame", "DecentContestFrame", UIParent, BACKDROP_TEMPLATE)
    UI.main = f
    f:SetSize(W, HGT)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not S.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
    f:SetBackdrop(FRAME_BACKDROP)
    f:SetBackdropColor(0.06, 0.03, 0.10, 0.96)
    f:SetBackdropBorderColor(0.63, 0.44, 1.0, 1)
    if S.pos then f:SetPoint(S.pos[1], UIParent, S.pos[2], S.pos[3], S.pos[4]) else f:SetPoint("CENTER") end
    f:SetScale(S.scale or 1)
    f:Hide()
    table.insert(UISpecialFrames, "DecentContestFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)
    f.title:SetText(COLOR .. "Decent|rContest  |cffccccccTransmog Contest|r")
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.sub:SetPoint("TOP", 0, -34)
    f.sub:SetWidth(W - 40)
    f.sub:SetWordWrap(false)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    Tooltip(close, "Close", "Close the contest window. You remain in any contest you joined.")
    local gear = MakeButton(f, "Settings", 74, ToggleSettings)
    gear:SetPoint("TOPRIGHT", close, "TOPLEFT", -2, -4)
    Tooltip(gear, "Settings", "Change the window style, scale, announcements, popups, and minimap icon.")
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20); icon:SetTexture("Interface\\Icons\\INV_Chest_Cloth_29")
    icon:SetPoint("RIGHT", f.title, "LEFT", -8, 0)

    local settings = CreateFrame("Frame", "DecentContestSettings", UIParent, BACKDROP_TEMPLATE)
    UI.settings = settings
    settingsFrame = settings
    settings:SetSize(340, 340); settings:SetPoint("CENTER", 220, 0)
    settings:SetFrameStrata("DIALOG"); settings:SetClampedToScreen(true); settings:EnableMouse(true)
    settings:SetMovable(true); settings:RegisterForDrag("LeftButton")
    settings:SetScript("OnDragStart", function(self) if not S.locked then self:StartMoving() end end)
    settings:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    settings:SetBackdrop(FRAME_BACKDROP); settings:SetBackdropColor(.06, .03, .10, .96)
    settings:SetBackdropBorderColor(.63, .44, 1, 1)
    table.insert(UISpecialFrames, "DecentContestSettings")
    settings.title = settings:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    settings.title:SetPoint("TOPLEFT", 18, -18); settings.title:SetText("DecentContest Settings")
    local settingsClose = CreateFrame("Button", nil, settings, "UIPanelCloseButton")
    settingsClose:SetPoint("TOPRIGHT", -2, -2); settingsClose:SetScript("OnClick", function() settings:Hide() end)
    Tooltip(settingsClose, "Close settings", "Close this window. Your choices are saved automatically.")
    local function setting(text, key, y, help)
        local check = MakeCheck(settings, text, key, y)
        Tooltip(check, text, help)
        return check
    end
    settings.settingsChecks = {}
    setting("Use Blizzard-style window", "blizzardUI", -58,
        "Use the game's marble frame, rock inset panels, and native tab artwork. Turn it off to return to the purple DecentContest theme.")
    setting("Lock window positions", "locked", -92,
        "Prevent dragging the main window, settings window, and minimap icon. The icon can still be clicked.")
    setting("Show minimap icon", "minimap", -126,
        "Show the clothing icon on the minimap. Left-click opens the contest; right-click opens these settings.")
    setting("Announce contest events in chat", "announce", -160,
        "Post lobby, start, and result announcements to the selected group or guild channel. Contest data itself uses addon messages.")
    setting("Open window when a contest starts", "popup", -194,
        "Automatically show the contest window when another player opens a lobby.")
    setting("Show window on login", "showOnLogin", -228,
        "Open the contest window when you enter the world.")
    local scaleLabel = settings:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleLabel:SetPoint("TOPLEFT", 18, -274); scaleLabel:SetText("Window scale: " .. math.floor((S.scale or 1) * 100 + .5) .. "%")
    local scale = CreateFrame("Slider", nil, settings, BACKDROP_TEMPLATE)
    scale:SetPoint("TOPLEFT", 18, -302); scale:SetSize(285, 16); scale:SetMinMaxValues(.6, 1.5)
    scale:SetValueStep(.05); if scale.SetObeyStepOnDrag then scale:SetObeyStepOnDrag(true) end
    scale:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", tile = true, tileSize = 8, edgeSize = 8 })
    scale:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    scale:SetValue(S.scale or 1)
    local low = settings:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", 2, -2); low:SetText("60%")
    local high = settings:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", scale, "BOTTOMRIGHT", -2, -2); high:SetText("150%")
    scale:SetScript("OnValueChanged", function(_, value)
        S.scale = math.floor(value * 20 + .5) / 20
        scaleLabel:SetText("Window scale: " .. math.floor(S.scale * 100 + .5) .. "%")
        UI.main:SetScale(S.scale)
    end)
    Tooltip(scale, "Window scale", "Adjust the contest window size from 60% to 150%.")
    settings:Hide()
    UI.applyTheme = ApplyTheme
    ApplyTheme()
    f:SetScript("OnShow", function() Refresh() end)

    local function View()
        local v = CreateFrame("Frame", nil, f)
        v:SetPoint("TOPLEFT", 12, -58)
        v:SetPoint("BOTTOMRIGHT", -12, 12)
        v:Hide()
        return v
    end

    -------------------------------------------------------------------
    -- Idle view: host a contest
    -------------------------------------------------------------------
    local idle = View(); UI.idle = idle
    idle.info = MakeLabel(idle, "", "GameFontHighlight")
    idle.info:SetPoint("TOPLEFT", 4, -4)
    idle.info:SetWidth(W - 40)
    idle.info:SetText("No contest is running. When someone in your group or guild opens one, it appears here.")

    local hb = MakeBox(idle, W - 24, 120, "Host a contest")
    idle.hostBox = hb
    hb:SetPoint("TOPLEFT", 0, -34)
    local tl = MakeLabel(hb, "Theme:", "GameFontNormal")
    tl:SetPoint("TOPLEFT", 14, -40)
    idle.theme = MakeEditBox(hb, 470, MAX_THEME)
    idle.theme:SetPoint("LEFT", tl, "RIGHT", 12, 0)
    idle.theme:SetScript("OnEnterPressed", function(self) self:ClearFocus(); HostOpen(self:GetText()) end)
    Tooltip(idle.theme, "Contest theme", "Enter a short theme for contestants to build their outfit around. The host announces it when the lobby opens.")
    idle.chan = MakeButton(hb, "", 150, function()
        S.channel = (S.channel == "GROUP") and "GUILD" or "GROUP"
        Refresh()
    end)
    idle.chan:SetPoint("TOPLEFT", 14, -76)
    idle.open = MakeButton(hb, "Open Lobby", 150, function() HostOpen(idle.theme:GetText()) end)
    idle.open:SetPoint("LEFT", idle.chan, "RIGHT", 10, 0)
    Tooltip(idle.open, "Open lobby", "Create a lobby. Players can join as judges or contestants, and the host can check the role lists before starting.")
    Tooltip(idle.chan, "Contest channel", "Choose the group or guild that receives this contest's addon messages and announcements.")
    idle.chanNote = MakeLabel(hb, "", "GameFontDisableSmall")
    idle.chanNote:SetPoint("LEFT", idle.open, "RIGHT", 12, 0)
    idle.chanNote:SetWidth(260)

    local how = MakeBox(idle, W - 24, 230, "How it works")
    how:SetPoint("TOPLEFT", hb, "BOTTOMLEFT", 0, -10)
    local ht = MakeLabel(how, "", "GameFontHighlightSmall")
    ht:SetPoint("TOPLEFT", 14, -30)
    ht:SetWidth(W - 60)
    ht:SetSpacing(4)
    ht:SetText(table.concat({
        "1.  The host picks a theme and opens a lobby for their group or guild.",
        "2.  Everyone with DecentContest joins as a |cff80c0ffJudge|r or a |cffffd200Contestant|r.",
        "3.  The host starts the contest. Everyone is told who the judges are, and the roster is locked until it ends.",
        "4.  Judges open each contestant's tab and rate them 1-10 on:",
        "        Theme & Cohesion  -  Color Coordination  -  Creativity",
        "5.  When every judge has submitted, all scores are added up. Highest overall total wins!",
        "",
        "|cffaaaaaaContestants must be in your group to show up in the 3D preview. Use /dcon history for past winners.|r",
    }, "\n"))

    -------------------------------------------------------------------
    -- Lobby view
    -------------------------------------------------------------------
    local lobby = View(); UI.lobby = lobby
    lobby.role = MakeLabel(lobby, "", "GameFontNormal")
    lobby.role:SetPoint("TOPLEFT", 4, -2)
    local half = (W - 24 - 10) / 2
    lobby.judgeCard = MakeBox(lobby, half, 84, "Judge")
    lobby.judgeCard:SetPoint("TOPLEFT", 0, -24)
    lobby.contestCard = MakeBox(lobby, half, 84, "Contestant")
    lobby.contestCard:SetPoint("TOPRIGHT", 0, -24)
    lobby.judgeCard.description = MakeLabel(lobby.judgeCard, "Rate each contestant on three categories. Judges do not compete.", "GameFontDisableSmall")
    lobby.judgeCard.description:SetPoint("TOPLEFT", 12, -30); lobby.judgeCard.description:SetWidth(half - 24); lobby.judgeCard.description:SetWordWrap(true)
    lobby.contestCard.description = MakeLabel(lobby.contestCard, "Present your outfit for the judges. Contestants do not score.", "GameFontDisableSmall")
    lobby.contestCard.description:SetPoint("TOPLEFT", 12, -30); lobby.contestCard.description:SetWidth(half - 24); lobby.contestCard.description:SetWordWrap(true)
    lobby.judge = MakeButton(lobby.judgeCard, "Choose Judge", half - 24, function() JoinAs("J") end)
    lobby.judge:SetPoint("BOTTOM", 0, 7)
    lobby.contest = MakeButton(lobby.contestCard, "Choose Contestant", half - 24, function() JoinAs("C") end)
    lobby.contest:SetPoint("BOTTOM", 0, 7)
    Tooltip(lobby.judgeCard, "Judge", "Choose this role to score every contestant. Your scores are private until results are calculated.")
    Tooltip(lobby.contestCard, "Contestant", "Choose this role to compete. Judges score your outfit using the displayed theme and criteria.")
    Tooltip(lobby.judge, "Join as judge", "Add yourself to the judge roster. You can switch roles or leave before the host starts.")
    Tooltip(lobby.contest, "Join as contestant", "Add yourself to the contestant roster. You can switch roles or leave before the host starts.")
    lobby.jbox = MakeBox(lobby, half, 190, "Judges")
    lobby.jbox:SetPoint("TOPLEFT", lobby.judgeCard, "BOTTOMLEFT", 0, -8)
    lobby.cbox = MakeBox(lobby, half, 190, "Contestants")
    lobby.cbox:SetPoint("TOPRIGHT", lobby.contestCard, "BOTTOMRIGHT", 0, -8)
    for _, b in ipairs({ lobby.jbox, lobby.cbox }) do
        b.list = MakeLabel(b, "", "GameFontHighlight")
        b.list:SetPoint("TOPLEFT", 14, -30)
        b.list:SetWidth(half - 28)
        b.list:SetJustifyV("TOP")
        b.list:SetSpacing(3)
    end
    lobby.note = MakeLabel(lobby, "Once the host starts, judges and contestants are locked in until the contest ends.", "GameFontDisableSmall")
    lobby.note:SetPoint("TOPLEFT", lobby.jbox, "BOTTOMLEFT", 4, -6)
    Tooltip(lobby.note, "Before the contest starts", "Review the judge and contestant lists. Starting locks these roles until the contest ends.")
    lobby.leave = MakeButton(lobby, "Leave", 80, function() JoinAs("X") end)
    lobby.leave:SetPoint("BOTTOMLEFT", 0, 0)
    Tooltip(lobby.leave, "Leave contest", "Remove yourself from the roster while the lobby is open.")
    lobby.cancel = MakeButton(lobby, "Cancel Contest", 120, function()
        Confirm("Cancel this transmog contest?", function() HostCancel() end)
    end)
    lobby.cancel:SetPoint("BOTTOMRIGHT", 0, 0)
    Tooltip(lobby.cancel, "Cancel contest", "Cancel the lobby for everyone. This cannot be undone.")
    lobby.start = MakeButton(lobby, "Start Contest", 120, function()
        if not H then return end
        Confirm(("Start the contest?\n\n%s and %s will be locked in until it ends.")
            :format(Plural(HostCount("J"), "judge"), Plural(HostCount("C"), "contestant")), HostStart)
    end)
    lobby.start:SetPoint("RIGHT", lobby.cancel, "LEFT", -6, 0)
    Tooltip(lobby.start, "Start contest", "Lock the roster and begin judging. At least one judge and one contestant are required.")

    -------------------------------------------------------------------
    -- Judge view: tabs per contestant, model, 3 sliders
    -------------------------------------------------------------------
    local judge = View(); UI.judge = judge
    local TAB_ROWS, TAB_H = 13, 24
    local tabsBox = MakeBox(judge, 172, 350)
    tabsBox:SetPoint("TOPLEFT", 0, 0)
    local tabsTitle = MakeLabel(tabsBox, "Contestants", "GameFontNormal")
    tabsTitle:SetPoint("TOPLEFT", 10, -8)
    judge.tabs = {}
    UI.blizzardTabs = {}
    for i = 1, TAB_ROWS do
        local b = CreateFrame("Button", nil, tabsBox, BACKDROP_TEMPLATE)
        b:SetSize(152, TAB_H - 2)
        b:SetPoint("TOPLEFT", 10, -26 - (i - 1) * TAB_H)
        b:SetBackdrop(FLAT_BACKDROP)
        UI.blizzardTabs[#UI.blizzardTabs + 1] = b
        b.text = MakeLabel(b, "", "GameFontHighlight")
        b.text:SetPoint("LEFT", 8, 0)
        b.text:SetPoint("RIGHT", -22, 0)
        b.text:SetWordWrap(false)
        b.check = b:CreateTexture(nil, "OVERLAY")
        b.check:SetSize(14, 14)
        Tooltip(b, "Contestant scorecard", "Select this contestant to view their model and enter scores for Theme & Cohesion, Color Coordination, and Creativity.")
        b.check:SetPoint("RIGHT", -5, 0)
        b.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b:SetScript("OnClick", function(self) UI.sel = self.index; Refresh() end)
        judge.tabs[i] = b
    end
    tabsBox:EnableMouseWheel(true)
    tabsBox:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #game.contestants - TAB_ROWS)
        UI.tabOffset = math.max(0, math.min(maxOff, (UI.tabOffset or 0) - delta))
        Refresh()
    end)
    judge.TAB_ROWS = TAB_ROWS

    local panel = MakeBox(judge, W - 24 - 180, 350)
    panel:SetPoint("TOPLEFT", tabsBox, "TOPRIGHT", 8, 0)
    judge.name = MakeLabel(panel, "", "GameFontNormalLarge")
    judge.name:SetPoint("TOPLEFT", 14, -10)
    judge.name:SetWidth(300)
    judge.name:SetWordWrap(false)
    judge.count = MakeLabel(panel, "", "GameFontDisableSmall")
    judge.count:SetPoint("TOPRIGHT", -14, -14)

    local mbox = MakeBox(panel, 170, 250)
    mbox:SetPoint("TOPLEFT", 10, -36)
    mbox:SetBackdropColor(0.02, 0.02, 0.04, 0.9)
    local model = CreateFrame("PlayerModel", nil, mbox)
    model:SetPoint("TOPLEFT", 4, -4)
    model:SetPoint("BOTTOMRIGHT", -4, 4)
    model:EnableMouse(true)
    model:EnableMouseWheel(true)
    model:SetScript("OnMouseDown", function(self)
        self.dragX = GetCursorPosition()
        self.dragFacing = self:GetFacing() or 0
    end)
    model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    model:SetScript("OnHide", function(self) self.dragX = nil end)
    model:SetScript("OnUpdate", function(self)
        if self.dragX then
            local x = GetCursorPosition()
            self:SetFacing(self.dragFacing + (x - self.dragX) / 70)
        end
    end)
    model:SetScript("OnMouseWheel", function(self, delta)
        if not self.SetCamDistanceScale then return end
        self.zoom = math.max(0.4, math.min(1.6, (self.zoom or 1) - delta * 0.1))
        self:SetCamDistanceScale(self.zoom)
    end)
    judge.model = model
    judge.modelMsg = MakeLabel(mbox, "", "GameFontDisableSmall")
    judge.modelMsg:SetPoint("CENTER")
    judge.modelMsg:SetWidth(150)
    judge.modelMsg:SetJustifyH("CENTER")
    local hint = MakeLabel(panel, "Drag to rotate, scroll to zoom", "GameFontDisableSmall")
    hint:SetPoint("TOP", mbox, "BOTTOM", 0, -2)
    judge.inspect = MakeButton(panel, "Inspect", 82, function()
        local e = game.contestants[UI.sel]
        local unit = e and UnitForGUID(e.guid)
        if unit and CanInspect(unit) and InspectUnit then
            InspectUnit(unit)
        else
            Print(("Can't inspect %s from here. Get closer or target them."):format(e and e.name or "them"))
        end
    end)
    judge.inspect:SetPoint("TOPLEFT", mbox, "BOTTOMLEFT", 0, -16)
    judge.reload = MakeButton(panel, "Refresh", 82, function() UI.modelGuid = nil; Refresh() end)
    judge.reload:SetPoint("LEFT", judge.inspect, "RIGHT", 6, 0)

    judge.rows = {}
    local function OnScore(key, v)
        local e = game.contestants[UI.sel]
        if not e or not draft or draft.submitted then return end
        v = math.max(1, math.min(10, v))
        DraftScore(e.slot)[key] = v
        Refresh()
    end
    for i, crit in ipairs(CRITERIA) do
        local row = {}
        row.label = MakeLabel(panel, crit.label, "GameFontNormal")
        row.label:SetPoint("TOPLEFT", mbox, "TOPRIGHT", 16, -6 - (i - 1) * 66)
        Tooltip(row.label, crit.label, i == 1 and "Score how clearly the outfit matches the announced theme and how cohesive the overall look feels. Use 1 for a weak match and 10 for an excellent match."
            or i == 2 and "Score how well the outfit's colors work together. Use 1 for clashing colors and 10 for a polished palette."
            or "Score the originality and visual interest of the outfit. Use 1 for a familiar look and 10 for a highly creative presentation.")
        row.slider = MakeSlider(panel, 190, function(v) OnScore(crit.key, v) end)
        row.slider:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -8)
        row.box = MakeEditBox(panel, 28, 2, true)
        row.box:SetPoint("LEFT", row.slider, "RIGHT", 12, 0)
        row.box:SetJustifyH("CENTER")
        row.box:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local n = tonumber(self:GetText())
            if n and n >= 1 and n <= 10 then OnScore(crit.key, n) end
        end)
        row.box:SetScript("OnEditFocusLost", function() Refresh() end)
        judge.rows[i] = row
    end
    judge.total = MakeLabel(panel, "", "GameFontNormalLarge")
    judge.total:SetPoint("TOPLEFT", mbox, "TOPRIGHT", 16, -6 - #CRITERIA * 66)
    judge.prev = MakeButton(panel, "< Prev", 80, function() UI.sel = math.max(1, UI.sel - 1); Refresh() end)
    judge.prev:SetPoint("BOTTOMRIGHT", -96, 12)
    judge.next = MakeButton(panel, "Next >", 80, function() UI.sel = math.min(#game.contestants, UI.sel + 1); Refresh() end)
    judge.next:SetPoint("BOTTOMRIGHT", -12, 12)

    judge.status = MakeLabel(judge, "", "GameFontHighlightSmall")
    judge.status:SetPoint("TOPLEFT", tabsBox, "BOTTOMLEFT", 4, -8)
    judge.status:SetWidth(W - 60)
    judge.status:SetWordWrap(false)
    judge.submit = MakeButton(judge, "Submit Final Scores", 170, function()
        if draft and draft.submitted then SubmitScores() return end   -- resend
        Confirm("Submit your scores for every contestant?\n\nYou can't change them afterwards.", SubmitScores)
    end)
    Tooltip(judge.submit, "Submit scores", "Submit your final scores for all contestants. Submitted scores are locked; you may resend them if the host has not received them.")
    judge.submit:SetPoint("BOTTOMRIGHT", 0, 0)
    judge.endBtn = MakeButton(judge, "End Judging", 110, function()
        Confirm("End judging now?\n\nOnly judges who have already submitted will be counted.", HostFinalize)
    end)
    judge.endBtn:SetPoint("BOTTOMLEFT", 0, 0)
    judge.cancel = MakeButton(judge, "Cancel Contest", 120, function()
        Confirm("Cancel this transmog contest? No winner will be picked.", function() HostCancel() end)
    end)
    judge.cancel:SetPoint("LEFT", judge.endBtn, "RIGHT", 6, 0)

    -------------------------------------------------------------------
    -- Watch view (contestants / spectators while judging)
    -------------------------------------------------------------------
    local watch = View(); UI.watch = watch
    watch.role = MakeLabel(watch, "", "GameFontNormal")
    watch.role:SetPoint("TOPLEFT", 4, -2)
    watch.role:SetWidth(W - 40)
    watch.jbox = MakeBox(watch, half, 330, "Judges")
    watch.jbox:SetPoint("TOPLEFT", 0, -24)
    watch.cbox = MakeBox(watch, half, 330, "Contestants")
    watch.cbox:SetPoint("TOPRIGHT", 0, -24)
    for _, b in ipairs({ watch.jbox, watch.cbox }) do
        b.list = MakeLabel(b, "", "GameFontHighlight")
        b.list:SetPoint("TOPLEFT", 14, -30)
        b.list:SetWidth(half - 28)
        b.list:SetJustifyV("TOP")
        b.list:SetSpacing(3)
    end
    watch.endBtn = MakeButton(watch, "End Judging", 110, function()
        Confirm("End judging now?\n\nOnly judges who have already submitted will be counted.", HostFinalize)
    end)
    watch.endBtn:SetPoint("BOTTOMLEFT", 0, 0)
    watch.cancel = MakeButton(watch, "Cancel Contest", 120, function()
        Confirm("Cancel this transmog contest? No winner will be picked.", function() HostCancel() end)
    end)
    watch.cancel:SetPoint("LEFT", watch.endBtn, "RIGHT", 6, 0)

    -------------------------------------------------------------------
    -- Results view
    -------------------------------------------------------------------
    local res = View(); UI.results = res
    res.banner = MakeLabel(res, "", "GameFontNormalHuge")
    res.banner:SetPoint("TOP", 0, -4)
    res.banner:SetWidth(W - 40)
    res.banner:SetJustifyH("CENTER")
    res.banner:SetWordWrap(false)
    res.info = MakeLabel(res, "", "GameFontHighlightSmall")
    res.info:SetPoint("TOP", res.banner, "BOTTOM", 0, -6)
    res.info:SetWidth(W - 40)
    res.info:SetJustifyH("CENTER")
    local tbl = MakeBox(res, W - 24, 300)
    tbl:SetPoint("TOPLEFT", 0, -56)
    local COLS = {
        { x = 10,  w = 26,  j = "RIGHT", h = "#" },
        { x = 44,  w = 190, j = "LEFT",  h = "Contestant" },
        { x = 240, w = 70,  j = "RIGHT", h = "Theme" },
        { x = 316, w = 70,  j = "RIGHT", h = "Color" },
        { x = 392, w = 80,  j = "RIGHT", h = "Creativity" },
        { x = 478, w = 60,  j = "RIGHT", h = "Total" },
        { x = 544, w = 66,  j = "RIGHT", h = "Avg" },
    }
    local RES_ROWS, RES_H = 14, 19
    for _, c in ipairs(COLS) do
        local fs = MakeLabel(tbl, c.h, "GameFontNormal")
        fs:SetPoint("TOPLEFT", c.x, -8)
        fs:SetWidth(c.w)
        fs:SetJustifyH(c.j)
    end
    res.rows = {}
    for i = 1, RES_ROWS do
        local row = {}
        for ci, c in ipairs(COLS) do
            local fs = MakeLabel(tbl, "", "GameFontHighlight")
            fs:SetPoint("TOPLEFT", c.x, -10 - i * RES_H)
            fs:SetWidth(c.w)
            fs:SetJustifyH(c.j)
            fs:SetWordWrap(false)
            row[ci] = fs
        end
        res.rows[i] = row
    end
    tbl:EnableMouseWheel(true)
    tbl:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #(game.standings or {}) - RES_ROWS)
        UI.resultsOffset = math.max(0, math.min(maxOff, (UI.resultsOffset or 0) - delta))
        Refresh()
    end)
    res.RES_ROWS = RES_ROWS
    res.done = MakeButton(res, "Done", 100, ClearLocal)
    res.done:SetPoint("BOTTOMRIGHT", 0, 0)
    res.announce = MakeButton(res, "Announce Top 3", 130, function()
        if not game.standings then return end
        local parts = {}
        for i = 1, math.min(3, #game.standings) do
            local s = game.standings[i]
            parts[#parts + 1] = ("#%d %s (%d)"):format(s.rank, s.name, s.total)
        end
        Announce(("Results for \"%s\": %s"):format(game.theme or "", table.concat(parts, ", ")))
    end)
    Tooltip(res.announce, "Announce top 3", "Post the top three contestants and scores to the selected group or guild chat channel.")
    res.announce:SetPoint("BOTTOMLEFT", 0, 0)
    ApplyTheme()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function RoleColor(role)
    return role == "J" and "|cff80c0ff" or "|cffffd200"
end

local function NameLines(list, decorate, max)
    max = max or 16
    local lines = {}
    for i, e in ipairs(list) do
        if i > max then
            lines[#lines + 1] = ("|cffaaaaaa...and %d more|r"):format(#list - max)
            break
        end
        local n = e.name
        if e.guid == MyGUID() then n = "|cff40ff40" .. n .. " (you)|r" end
        lines[#lines + 1] = decorate and decorate(e, n) or n
    end
    if #lines == 0 then lines[1] = "|cff888888nobody yet|r" end
    return table.concat(lines, "\n")
end

local function UpdateModel(e)
    local j = UI.judge
    if UI.modelGuid == (e and e.guid) and j.model.ok then return end
    UI.modelGuid = e and e.guid
    j.model.ok = false
    j.model:ClearModel()
    local unit = e and UnitForGUID(e.guid)
    if not unit then
        j.modelMsg:SetText("Not in your group.\nTarget them and press Refresh to preview.")
    elseif not UnitIsVisible(unit) then
        j.modelMsg:SetText("Too far away to preview.\nGet closer and press Refresh.")
    else
        j.modelMsg:SetText("")
        j.model:SetUnit(unit)
        j.model:SetFacing(0)
        j.model.zoom = 1
        if j.model.SetCamDistanceScale then j.model:SetCamDistanceScale(1) end
        j.model.ok = true
    end
end

local function RefreshJudge(isHost)
    local j = UI.judge
    local list = game.contestants
    UI.sel = math.max(1, math.min(UI.sel or 1, #list))
    -- keep the selected tab visible
    UI.tabOffset = UI.tabOffset or 0
    if UI.sel <= UI.tabOffset then UI.tabOffset = UI.sel - 1 end
    if UI.sel > UI.tabOffset + j.TAB_ROWS then UI.tabOffset = UI.sel - j.TAB_ROWS end

    for i, b in ipairs(j.tabs) do
        local idx = UI.tabOffset + i
        local e = list[idx]
        if e then
            b.index = idx
            b.text:SetText(e.name)
            b.check:SetShown(IsScored(e.slot))
            if idx == UI.sel then
                b:SetBackdropColor(0.36, 0.22, 0.62, 0.95)
                b:SetBackdropBorderColor(0.75, 0.6, 1, 1)
            else
                b:SetBackdropColor(0.12, 0.07, 0.18, 0.85)
                b:SetBackdropBorderColor(0.3, 0.22, 0.45, 1)
            end
            b:Show()
        else
            b:Hide()
        end
    end

    local e = list[UI.sel]
    local locked = draft and draft.submitted
    j.name:SetText(e and (RoleColor("C") .. e.name .. "|r") or "")
    j.count:SetText(e and ("Contestant %d of %d"):format(UI.sel, #list) or "")
    UpdateModel(e)

    local s = e and draft and draft.scores[e.slot] or {}
    local total, complete = 0, true
    for i, crit in ipairs(CRITERIA) do
        local row, v = j.rows[i], s[crit.key]
        row.slider:SetQuiet(v or 5)
        row.slider:GetThumbTexture():SetAlpha(v and 1 or 0.35)
        if not row.box:HasFocus() then row.box:SetText(v and tostring(v) or "") end
        if locked then row.slider:Disable(); row.box:Disable() else row.slider:Enable(); row.box:Enable() end
        row.slider:EnableMouse(not locked)
        if v then total = total + v else complete = false end
    end
    j.total:SetText(complete and ("Score: |cffffffff%d|r / %d"):format(total, MAX_PER_JUDGE)
        or "|cffaaaaaaMove all three sliders to score|r")
    j.prev:SetEnabled(UI.sel > 1)
    j.next:SetEnabled(UI.sel < #list)

    local done, parts = 0, {}
    for _, je in ipairs(game.judges) do
        local ok = game.judgeDone[je.slot]
        if ok then done = done + 1 end
        parts[#parts + 1] = (ok and "|cff40ff40" or "|cffaaaaaa") .. je.name .. "|r"
    end
    j.status:SetText(("Judges (%d/%d submitted): %s"):format(done, #game.judges, table.concat(parts, ", ")))

    if locked then
        local acked = game.judgeDone[game.mySlot]
        j.submit:SetText(acked and "Scores Submitted" or "Resend Scores")
        j.submit:SetEnabled(not acked)
    else
        j.submit:SetText("Submit Final Scores")
        j.submit:SetEnabled(AllScored())
    end
    j.endBtn:SetShown(isHost)
    j.cancel:SetShown(isHost)
end

function Refresh()
    if not UI.main then return end
    local f = UI.main
    for _, v in ipairs({ UI.idle, UI.lobby, UI.judge, UI.watch, UI.results }) do v:Hide() end
    local isHost = H ~= nil and game.hostIsMe and true or false
    local phase = game.phase
    f:SetScale(S.scale or 1)
    if UI.settings then UI.settings:SetScale(S.scale or 1) end

    if phase == "idle" then
        f.sub:SetText("|cffaaaaaaWaiting for a contest|r")
        local v = UI.idle
        if not v.theme:HasFocus() and v.theme:GetText() == "" then v.theme:SetText(S.lastTheme or "") end
        v.chan:SetText("Channel: " .. CHANNEL_LABEL[S.channel])
        local live = ResolveChannel(S.channel)
        v.chanNote:SetText(live and ("Players in your %s with the addon can join."):format(S.channel == "GUILD" and "guild" or "group")
            or "|cffffd200Not in one - local test mode.|r")
        v:Show()
        return
    end

    f.sub:SetText(("Theme: |cffffd200%s|r   Host: %s   %s"):format(game.theme or "?", game.host or "?",
        phase == "lobby" and "|cff40ff40Lobby open|r" or phase == "judging" and "|cffff9030Judging (locked)|r" or "|cff80c0ffResults|r"))

    if phase == "lobby" then
        local v = UI.lobby
        local you = game.myRole == "J" and (RoleColor("J") .. "a Judge|r")
            or game.myRole == "C" and (RoleColor("C") .. "a Contestant|r") or "|cffaaaaaanot joined|r"
        v.role:SetText("You are " .. you .. (isHost and "   |cffa070ff(you are hosting)|r" or ""))
        v.jbox.title:SetText(("Judges (%d)"):format(#game.judges))
        v.cbox.title:SetText(("Contestants (%d)"):format(#game.contestants))
        v.jbox.list:SetText(NameLines(game.judges))
        v.cbox.list:SetText(NameLines(game.contestants))
        v.judge:SetEnabled(game.myRole ~= "J")
        v.contest:SetEnabled(game.myRole ~= "C")
        v.judge:SetText(game.myRole == "J" and "Selected: Judge" or "Choose Judge")
        v.contest:SetText(game.myRole == "C" and "Selected: Contestant" or "Choose Contestant")
        if v.judgeCard.SetBackdropColor then
            v.judgeCard:SetBackdropColor(game.myRole == "J" and .13 or 0, game.myRole == "J" and .12 or 0, game.myRole == "J" and .22 or 0, game.myRole == "J" and .95 or .55)
            v.contestCard:SetBackdropColor(game.myRole == "C" and .2 or 0, game.myRole == "C" and .12 or 0, game.myRole == "C" and .02 or 0, game.myRole == "C" and .95 or .55)
        end
        v.leave:SetEnabled(game.myRole ~= nil)
        v.start:SetShown(isHost)
        v.cancel:SetShown(isHost)
        v.start:SetEnabled(#game.judges > 0 and #game.contestants > 0)
        v:Show()
    elseif phase == "judging" then
        if game.myRole == "J" and draft then
            RefreshJudge(isHost)
            UI.judge:Show()
        else
            local v = UI.watch
            if game.myRole == "C" then
                v.role:SetText("You are a " .. RoleColor("C") .. "Contestant|r. Strike a pose, the judges are scoring!")
            else
                v.role:SetText("|cffaaaaaaYou're spectating. The roster is locked until the contest ends.|r")
            end
            local done = 0
            for _, je in ipairs(game.judges) do if game.judgeDone[je.slot] then done = done + 1 end end
            v.jbox.title:SetText(("Judges (%d/%d submitted)"):format(done, #game.judges))
            v.cbox.title:SetText(("Contestants (%d)"):format(#game.contestants))
            v.jbox.list:SetText(NameLines(game.judges, function(e, n)
                return n .. (game.judgeDone[e.slot] and "  |cff40ff40Submitted|r" or "  |cffaaaaaascoring...|r")
            end))
            v.cbox.list:SetText(NameLines(game.contestants))
            v.endBtn:SetShown(isHost)
            v.cancel:SetShown(isHost)
            v:Show()
        end
    elseif phase == "results" then
        local v = UI.results
        local st = game.standings or {}
        local w, names = Winners(st), {}
        for i, s in ipairs(w) do names[i] = s.name end
        if #w > 0 then
            v.banner:SetText(("|cffffd200%s: %s|r"):format(#w > 1 and "Tie" or "Winner", table.concat(names, " & ")))
        else
            v.banner:SetText("No contestants")
        end
        v.info:SetText(("Overall score = all judges' points added together.  %s counted, max %d points per judge.")
            :format(Plural(game.judgesCounted or 0, "judge"), MAX_PER_JUDGE))
        UI.resultsOffset = UI.resultsOffset or 0
        for i, row in ipairs(v.rows) do
            local s = st[UI.resultsOffset + i]
            if s then
                local color = s.rank == 1 and "|cffffd200" or ""
                local me = game.bySlot[s.slot] and game.bySlot[s.slot].guid == MyGUID()
                row[1]:SetText(color .. s.rank)
                row[2]:SetText((me and "|cff40ff40" or color) .. s.name .. (me and " (you)" or ""))
                row[3]:SetText(s.t); row[4]:SetText(s.c); row[5]:SetText(s.r)
                row[6]:SetText(color .. s.total)
                row[7]:SetText(("%.1f"):format(s.avg))
            else
                for _, fs in ipairs(row) do fs:SetText("") end
            end
        end
        v.announce:SetShown(isHost)
        v:Show()
    end
end

---------------------------------------------------------------------------
-- History / slash commands
---------------------------------------------------------------------------
local function PrintHistory()
    if #DB.history == 0 then Print("No contests recorded yet.") return end
    Print("Recent contests:")
    for i = 1, math.min(10, #DB.history) do
        local h = DB.history[i]
        local winners = {}
        for _, s in ipairs(h.standings or {}) do
            if s.rank == 1 then winners[#winners + 1] = ("%s (%d)"):format(s.name, s.total) end
        end
        Print(("  %s  \"%s\"  winner: |cffffd200%s|r  judges: %s"):format(
            date("%m/%d %H:%M", h.time), h.theme or "?", #winners > 0 and table.concat(winners, " & ") or "-",
            JoinNames(h.judges or {}, 4)))
    end
end

local function ResetLocal()
    if H then HostCancel() end
    if DB.drafts and game.id then DB.drafts[game.id] = nil end
    game, draft = NewGame(), nil
    Print("Local contest state cleared.")
    Refresh()
end

SLASH_DECENTCONTEST1 = "/dcon"
SLASH_DECENTCONTEST2 = "/decentcontest"
SlashCmdList.DECENTCONTEST = function(input)
    input = strtrim(input or "")
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "host" or cmd == "open" then
        HostOpen(rest ~= "" and rest or S.lastTheme)
        UI.main:Show()
    elseif cmd == "start" then
        if H and H.phase == "lobby" then HostStart() else Print("You aren't hosting a contest lobby.") end
    elseif cmd == "end" then
        if H and H.phase == "judging" then HostFinalize() else Print("You aren't hosting a contest that is judging.") end
    elseif cmd == "cancel" then
        if H then HostCancel() else Print("You aren't hosting a contest.") end
    elseif cmd == "sync" then
        RequestSync(); Print("Asked the host to resend the contest.")
    elseif cmd == "history" then PrintHistory()
    elseif cmd == "reset" then
        Confirm("Clear your local contest state?\n\nIf you are the host this cancels the contest for everyone.", ResetLocal)
    elseif cmd == "resetpos" then
        S.pos = nil; UI.main:ClearAllPoints(); UI.main:SetPoint("CENTER"); UI.main:Show()
    elseif cmd == "announce" then
        S.announce = not S.announce
        Print("Chat announcements when hosting: " .. (S.announce and "on" or "off"))
    elseif cmd == "popup" then
        S.popup = not S.popup
        Print("Open window when a contest opens: " .. (S.popup and "on" or "off"))
    elseif cmd == "scale" then
        local n = tonumber(rest)
        if n and n >= 0.6 and n <= 1.5 then S.scale = n; UI.main:SetScale(n); if UI.settings then UI.settings:SetScale(n) end else Print("Usage: /dcon scale 0.6-1.5") end
    elseif cmd == "settings" or cmd == "config" then
        if settingsFrame then settingsFrame:Show() end
    elseif cmd == "minimap" then
        S.minimap = not S.minimap
        if minimapButton then minimapButton:SetShown(S.minimap) end
        Print("Minimap icon " .. (S.minimap and "shown." or "hidden."))
    elseif cmd == "help" then
        Print("/dcon - toggle window | /dcon host <theme> | /dcon start | /dcon end | /dcon cancel")
        Print("/dcon history | /dcon sync | /dcon reset | /dcon resetpos | /dcon settings | /dcon minimap | /dcon announce | /dcon popup | /dcon scale <n>")
    else
        UI.main:SetShown(not UI.main:IsShown())
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function InitDB()
    DecentContestDB = DecentContestDB or {}
    DB = DecentContestDB
    DB.settings = DB.settings or {}
    for k, v in pairs(DEFAULTS) do
        if DB.settings[k] == nil then DB.settings[k] = v end
    end
    S = DB.settings
    if S.channel ~= "GROUP" and S.channel ~= "GUILD" then S.channel = "GROUP" end
    S.scale = math.max(.6, math.min(1.5, tonumber(S.scale) or 1))
    DB.history = DB.history or {}
    DB.drafts = DB.drafts or {}
    DB.finished = DB.finished or {}
    if DB.host and DB.host.id and DB.host.roster and DB.host.phase ~= "done" then
        H = DB.host
        H.sparts = {}                       -- partial messages don't survive a reload
    else
        DB.host = nil
    end
end

local lastGroupSize = 0

DC:RegisterEvent("ADDON_LOADED")
DC:RegisterEvent("PLAYER_LOGIN")
DC:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then InitDB(); self:UnregisterEvent("ADDON_LOADED") end
    elseif event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end
        lastRefill = GetTime()
        lastGroupSize = GetNumGroupMembers()
        BuildMain()
        BuildMinimapButton()
        self:RegisterEvent("CHAT_MSG_ADDON")
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        -- Hosts resume their contest after a reload; everyone else asks to catch up.
        C_Timer.After(4, function()
            if H then
                Print("Resuming the contest you were hosting.")
                Resync()
            else
                RequestSync()
            end
        end)
        if S.showOnLogin then UI.main:Show() end
        if Minimap then Minimap:HookScript("OnSizeChanged", PositionMinimap) end
        Refresh()
        Print("loaded. Type /dcon to open, /dcon help for commands.")
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        local n = GetNumGroupMembers()
        if n > lastGroupSize then
            if H then ScheduleResync(3)                                   -- show the contest to newcomers
            elseif game.phase == "idle" and lastGroupSize == 0 then C_Timer.After(2, RequestSync) end
        end
        lastGroupSize = n
        if UI.main and UI.main:IsShown() then UI.modelGuid = nil; Refresh() end
    end
end)
