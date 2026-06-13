-- Optimal Raid Comp Manager (v2.8)
-- Author: Runshouse, Marco (Original design by Xhausted)
-- Features: Priest Shadow Res toggle, Shaman Totem Dropdown Tooltips,
--           Overwrite-on-Save profiles, optional ElvUI skinning.

local PADDING, SLOT_HEIGHT = 10, 30
local CLASS_COL_WIDTH, SPEC_COL_WIDTH = 100, 90
local VISIBLE_ROWS, MAX_ROWS, ROW_HEIGHT = 10, 25, 30

-- ==================== SAVED VARIABLES ====================
OptimalRaidCompDB = OptimalRaidCompDB or {
    comps = {},
    currentComp = nil,
    buttonPos = { x = -200, y = 0 },
    scale = 1.0,
    raidSize = 25
}

-- Seed saved-var defaults added after the addon's first release, so existing DBs
-- gain the new keys without clobbering the user's data.
do
    local db = OptimalRaidCompDB
    if db.selectedFormation == nil then db.selectedFormation = "Shield" end
    if db.selectedFormationIndex == nil then db.selectedFormationIndex = 1 end
    if db.controlExpanded == nil then db.controlExpanded = false end
    if db.autoLevelUp == nil then db.autoLevelUp = true end
    if db.tradeWhisper == nil then db.tradeWhisper = true end
    if db.cmdWinPos == nil then db.cmdWinPos = { x = 300, y = 0 } end
end

local activeSummonFrame = nil
local activeSortFrame = nil
local reinitPending = false      -- a re-init requested during combat; runs on regen
local pendingReinitComp = nil    -- comp snapshot to re-init once combat ends
local slots -- row data, built in the GUI section

-- Snapshot the visible UI rows into a comp table (same shape SummonComp/PushSpecs use).
-- Defined early so control-tab buttons and the level-up handler can reach it.
local function BuildCompFromSlots()
    local temp = { slots = {} }
    for j = 1, MAX_ROWS do
        temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer }
    end
    return temp
end

-- ==================== DATA TABLES & MAPPING ====================
local classes = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid", "DK" }
local specsByClass = {
    Warrior = {"prot", "arms", "fury"}, Paladin = {"prot", "holy", "ret"},
    Hunter = {"bm", "mm", "surv"}, Rogue = {"as", "combat", "subtlety"},
    Priest = {"holy", "disc", "shadow"}, Shaman = {"resto", "ele", "enh"},
    Mage = {"arcane", "fire", "frost"}, Warlock = {"affli", "demo", "destro"},
    Druid = {"bear", "cat", "resto", "balance"}, DK = {"blood", "frost", "unholy"},
}
local CLASS_TO_CMD = { Warrior="warrior", Paladin="paladin", Hunter="hunter", Rogue="rogue", Priest="priest", Shaman="shaman", Mage="mage", Warlock="warlock", Druid="druid", DK="dk" }
local UNIT_TO_SHORT = { WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter", ROGUE="Rogue", PRIEST="Priest", SHAMAN="Shaman", MAGE="Mage", WARLOCK="Warlock", DRUID="Druid", DEATHKNIGHT="DK" }

-- Translates UI selections into mod-playerbots strategy commands
local STRAT_MAP = {
    -- Paladin Blessings
    ["might"]     = "bdps",
    ["wisdom"]    = "bmana",
    ["kings"]     = "bstats",
    ["sanctuary"] = "bhealth",
    
    -- Auras & Resistances (Shared by Paladin/Priest)
    ["devotion"]      = "barmor",
    ["retribution"]   = "baoe",
    ["concentration"] = "bcast",
    ["fire res"]      = "rfire",
    ["frost res"]     = "rfrost",
    ["shadow res"]    = "rshadow",
    ["crusader"]      = "bspeed"
}

-- Descriptive Tooltips for Shaman Totem Sets
local TOTEM_TOOLTIPS = {
    ["melee"]      = "Earth: Strength of Earth\nFire: Flametongue / Magma\nWater: Healing Stream\nAir: Windfury",
    ["caster"]     = "Earth: Stoneskin\nFire: Totem of Wrath / Flametongue\nWater: Mana Spring\nAir: Wrath of Air",
    ["healing"]    = "Earth: Stoneskin\nFire: Flametongue\nWater: Mana Tide / Spring\nAir: Wrath of Air",
    ["fire res"]   = "Overrides Fire totem with Fire Resistance Totem.",
    ["frost res"]  = "Overrides Fire totem with Frost Resistance Totem.",
    ["nature res"] = "Overrides Air totem with Nature Resistance Totem."
}

-- ==================== SHARED INFRASTRUCTURE (bot control) ====================
-- Raid-aware order broadcast: bot behavior orders go to RAID in a raid, else PARTY.
-- (The original Warstorm Bot Manager was party-only; ORC supports 10/25-man, so
-- orders must reach raid members too.)
local function SendBotOrder(msg)
    if GetNumRaidMembers() > 0 then SendChatMessage(msg, "RAID")
    elseif GetNumPartyMembers() > 0 then SendChatMessage(msg, "PARTY")
    else print("|cffff0000[ORC] Not in a group -- order not sent.|r") end
end

-- Lightweight OnUpdate scheduler (3.3.5a has no guaranteed C_Timer). Runs queued
-- callbacks once their GetTime() target passes. Used to space chat commands and to
-- defer follow-up steps (spec confirms, autogear, loot, reinit).
local schedPending = {}
local schedFrame = CreateFrame("Frame")
schedFrame:SetScript("OnUpdate", function()
    if #schedPending == 0 then return end
    local now = GetTime()
    local i = 1
    while i <= #schedPending do
        if now >= schedPending[i].at then
            local item = table.remove(schedPending, i)
            local ok, err = pcall(item.fn)
            if not ok then print("|cffff0000[ORC] scheduled task error: "..tostring(err).."|r") end
        else
            i = i + 1
        end
    end
end)
local function After(delay, fn) table.insert(schedPending, { at = GetTime() + delay, fn = fn }) end

-- Spec-confirmation tracking: after "talents spec ..." each bot replies in WHISPER
-- with "picking <spec>". We wait until every whispered bot confirms before sending
-- autogear, so gear isn't applied for a spec a bot hasn't switched to yet.
local awaitingSpecs = nil   -- { remaining = {name=true,...}, count, onDone, token }
local confirmFrame = CreateFrame("Frame")
confirmFrame:RegisterEvent("CHAT_MSG_WHISPER")
confirmFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not awaitingSpecs or not sender then return end
    local short = string.match(sender, "^[^-]+") or sender   -- strip "-Realm" if present
    if awaitingSpecs.remaining[short] and message and string.find(string.lower(message), "picking") then
        awaitingSpecs.remaining[short] = nil
        awaitingSpecs.count = awaitingSpecs.count - 1
        if awaitingSpecs.count <= 0 then
            local cb = awaitingSpecs.onDone
            awaitingSpecs = nil
            cb(true, {})
        end
    end
end)

-- Wait up to `timeout`s for every name in `names` (array) to whisper "picking ...".
-- onDone(allConfirmed, missing) fires exactly once: immediately when all confirm, or
-- at the timeout with the still-missing names.
local function AwaitSpecConfirms(names, timeout, onDone)
    local remaining, count = {}, 0
    for _, n in ipairs(names or {}) do
        if not remaining[n] then remaining[n] = true; count = count + 1 end
    end
    if count == 0 then onDone(true, {}); return end
    local token = {}
    awaitingSpecs = { remaining = remaining, count = count, onDone = onDone, token = token }
    After(timeout, function()
        if awaitingSpecs and awaitingSpecs.token == token then
            local missing = {}
            for n in pairs(awaitingSpecs.remaining) do table.insert(missing, n) end
            awaitingSpecs = nil
            onDone(false, missing)
        end
    end)
end

local function WarnSpecMissing(missing)
    print("|cffff0000[ORC] WARNING - "..#missing.." bot(s) did not confirm spec: "..table.concat(missing, ", ").."|r")
end

-- ==================== CONTROL DATA ====================
-- Formations and their command tokens (Warstorm-specific).
local formations = {
    { name = "Shield", command = "shield" }, { name = "Chaos",  command = "chaos" },
    { name = "Circle", command = "circle" }, { name = "Line",   command = "line" },
    { name = "Melee",  command = "melee" },  { name = "Near",   command = "near" },
    { name = "Queue",  command = "queue" },  { name = "Arrow",  command = "arrow" },
}
-- Control grid: rows = roles (empty prefix = all bots), columns = actions.
local roles = {
    { label = "all",    prefix = "" },
    { label = "tank",   prefix = "@tank " },
    { label = "heal",   prefix = "@heal " },
    { label = "dps",    prefix = "@dps " },
    { label = "melee",  prefix = "@melee " },
    { label = "ranged", prefix = "@ranged " },
}
local actions = { "attack", "stay", "follow", "flee" }
-- Footer actions on the Control tab. command = nil means a custom OnClick.
local footer = {
    { label = "Summon",  command = "summon" },
    { label = "Release", command = "release" },
    { label = "Drink",   command = "drink" },
    { label = "Skull",   command = nil },          -- rti skull + attack rti target
    { label = "CC",      command = "rti cc moon" },
}

-- Context-Aware Mutually Exclusive Options
local function GetOptionsForClassSpec(class, spec)
    local opt1List, opt2List = nil, nil
    if class == "Paladin" then
        opt1List = {"kings", "might", "wisdom"}
        if spec == "prot" then table.insert(opt1List, "sanctuary") end
        opt2List = {"devotion", "retribution", "concentration", "fire res", "frost res", "shadow res"}
    elseif class == "Shaman" then
        opt1List = {"melee", "caster", "healing", "fire res", "frost res", "nature res"}
    elseif class == "Priest" then
        opt1List = {"shadow res"}
    end
    return opt1List, opt2List
end

-- Initialize Default 5-Man Comp
local default5Man = {
    name = "Default 5-Man",
    size = 5,
    slots = {
        { class = "Paladin", spec = "ret", opt1 = "might", opt2 = "retribution", isPlayer = true },
        { class = "Warrior", spec = "prot", opt1 = "none", opt2 = "none", isPlayer = false },
        { class = "Priest", spec = "holy", opt1 = "none", opt2 = "none", isPlayer = false },
        { class = "Rogue", spec = "combat", opt1 = "none", opt2 = "none", isPlayer = false },
        { class = "Hunter", spec = "bm", opt1 = "none", opt2 = "none", isPlayer = false },
    }
}
for i = 6, 25 do table.insert(default5Man.slots, {class="Warrior", spec="prot", opt1="none", opt2="none", isPlayer=false}) end

if not OptimalRaidCompDB.comps["Default 5-Man"] then
    OptimalRaidCompDB.comps["Default 5-Man"] = default5Man
    if not OptimalRaidCompDB.currentComp then OptimalRaidCompDB.currentComp = "Default 5-Man" end
end

-- ==================== CORE LOGIC ====================
local function GetPartyMembers()
    local members = {}
    local isRaid = GetNumRaidMembers() > 0
    local num = isRaid and GetNumRaidMembers() or GetNumPartyMembers()
    for i = 1, num do
        local unit = isRaid and ("raid"..i) or ("party"..i)
        local name = UnitName(unit)
        if name then
            local _, eng = UnitClass(unit)
            table.insert(members, { name = name, class = eng })
        end
    end
    return members, isRaid
end

-- --- RAID SORTING LOGIC ---
local function SortRaidGroup(comp)
    if OptimalRaidCompDB.raidSize <= 5 or GetNumRaidMembers() == 0 then return end
    if activeSortFrame then activeSortFrame:Hide() end
    
    print("|cff00ff00[ORC] Calculating Role Assignments...|r")
    
    local unassigned = {}
    for i = 1, GetNumRaidMembers() do
        local name, _, group, _, _, classFileName = GetRaidRosterInfo(i)
        if name then table.insert(unassigned, {name=name, class=UNIT_TO_SHORT[classFileName], currentGroup=group, raidIndex=i}) end
    end

    local slotUsed = {}
    for _, u in ipairs(unassigned) do
        local matched = false
        for sIdx, slot in ipairs(comp.slots) do
            if not slotUsed[sIdx] and slot.class == u.class then
                if (slot.isPlayer and u.name == UnitName("player")) or (not slot.isPlayer and u.name ~= UnitName("player")) then
                    slotUsed[sIdx] = true
                    u.spec = slot.spec
                    if u.spec == "holy" or u.spec == "disc" or u.spec == "resto" then u.role = "H"
                    elseif u.class == "Warrior" or u.class == "Rogue" or u.class == "DK" or u.spec == "prot" or u.spec == "ret" or u.spec == "bear" or u.spec == "cat" or u.spec == "enh" then u.role = "M"
                    else u.role = "R" end
                    matched = true
                    break
                end
            end
        end
        if not matched then u.role = "R" end 
    end

    local groups = {{}, {}, {}, {}, {}, {}, {}, {}}
    local mQueue, rQueue, hQueue = {}, {}, {}
    for _, u in ipairs(unassigned) do
        if u.role == "M" then table.insert(mQueue, u)
        elseif u.role == "R" then table.insert(rQueue, u)
        else table.insert(hQueue, u) end
    end

    local cg = 1
    local function AddToGroup(unit)
        if #groups[cg] >= 5 then cg = cg + 1 end
        table.insert(groups[cg], unit)
    end

    while #mQueue > 0 do AddToGroup(table.remove(mQueue, 1)) end
    while #groups[cg] > 0 and #groups[cg] < 5 do
        if #hQueue > 0 then AddToGroup(table.remove(hQueue, 1)) elseif #rQueue > 0 then AddToGroup(table.remove(rQueue, 1)) else break end
    end
    while #rQueue > 0 do AddToGroup(table.remove(rQueue, 1)) end
    while #groups[cg] > 0 and #groups[cg] < 5 do
        if #hQueue > 0 then AddToGroup(table.remove(hQueue, 1)) else break end
    end
    while #hQueue > 0 do AddToGroup(table.remove(hQueue, 1)) end

    local targetGroup = {}
    for gNum, gList in ipairs(groups) do
        for _, u in ipairs(gList) do targetGroup[u.name] = gNum end
    end

    print("|cff00ff00[ORC] Sorting Raid in progress (Please wait)...|r")
    
    activeSortFrame = CreateFrame("Frame")
    activeSortFrame.lastTime = GetTime()
    
    activeSortFrame:SetScript("OnUpdate", function(self)
        if GetTime() - self.lastTime < 0.2 then return end
        self.lastTime = GetTime()

        local moved = false
        local currentGroups = {{},{},{},{},{},{},{},{}}
        local wrongPlayers = {}

        for i = 1, GetNumRaidMembers() do
            local name, _, group = GetRaidRosterInfo(i)
            if name then
                table.insert(currentGroups[group], {name=name, index=i})
                local tGroup = targetGroup[name]
                if tGroup and tGroup ~= group then table.insert(wrongPlayers, {name=name, index=i, current=group, target=tGroup}) end
            end
        end

        if #wrongPlayers == 0 then
            print("|cff00ff00[ORC] Raid Sorting Complete!|r")
            self:Hide(); self:SetScript("OnUpdate", nil); return
        end

        local p1 = wrongPlayers[1]
        if #currentGroups[p1.target] < 5 then
            SetRaidSubgroup(p1.index, p1.target); moved = true
        else
            for _, p2 in ipairs(currentGroups[p1.target]) do
                local t2 = targetGroup[p2.name]
                if t2 and t2 ~= p1.target then SwapRaidSubgroup(p1.index, p2.index); moved = true; break end
            end
        end
        
        if not moved then self:Hide(); self:SetScript("OnUpdate", nil) end
    end)
end

-- --- STANDALONE ACTIONS ---
local function CheckInstance()
    local playerZone = GetRealZoneText()
    local isRaid = GetNumRaidMembers() > 0
    local num = isRaid and GetNumRaidMembers() or GetNumPartyMembers()
    
    if num == 0 then print("|cffff0000[ORC] You are not in a group.|r"); return end
    print("|cff00ffff[ORC] Range Check (Zone: "..playerZone.."):|r")
    local allGood = true
    
    for i = 1, num do
        local unit = isRaid and ("raid"..i) or ("party"..i)
        local name = UnitName(unit)
        if name and name ~= UnitName("player") then
            if not UnitIsConnected(unit) then print("|cffff0000- " .. name .. " is OFFLINE.|r"); allGood = false
            elseif not UnitIsVisible(unit) then print("|cffffff00- " .. name .. " is OUT OF RANGE (or in another instance).|r"); allGood = false end
        end
    end
    if allGood then print("|cff00ff00All bots are online and within 100 yards!|r") end
end

local function PushAutogear()
    local _, isRaid = GetPartyMembers()
    SendChatMessage("autogear", isRaid and "RAID" or "PARTY")
    print("|cff00ff00[ORC] Autogear command sent.|r")
end

local function PushWorldBuffs()
    local _, isRaid = GetPartyMembers()
    SendChatMessage("nc +worldbuff", isRaid and "RAID" or "PARTY")
    print("|cff00ff00[ORC] World buff command sent.|r")
end

-- Am I the loot-controlling leader of the current group?
local function IsGroupLeader()
    if GetNumRaidMembers() > 0 then return IsRaidLeader()
    elseif GetNumPartyMembers() > 0 then return IsPartyLeader() end
    return false
end

-- Set Free For All loot with an Epic threshold (4). Method and threshold are set on
-- separate frames; setting both in one frame can drop the method change.
local function SetGroupLoot()
    if not IsGroupLeader() then return end
    SetLootMethod("freeforall")
    After(0.5, function()
        if IsGroupLeader() then SetLootThreshold(4) end   -- 2=uncommon 3=rare 4=epic
    end)
    print("|cff00ff00[ORC] Loot set to Free For All / Epic threshold.|r")
end

-- Whisper each bot its spec + strategy/totem tokens, assigning by class queue (each
-- desired spec consumed once). Returns the list of bot names whispered, so a caller
-- can wait for their "picking ..." confirmations before gearing.
local function WhisperCompSpecs(comp)
    local members = GetPartyMembers()
    local playerName = UnitName("player")
    local bots = {}
    for _, m in ipairs(members) do if m.name ~= playerName then table.insert(bots, m) end end

    local desired = {}
    for i = 1, OptimalRaidCompDB.raidSize do
        local s = comp.slots[i]
        if s and not s.isPlayer then table.insert(desired, { class = s.class, spec = s.spec, opt1 = s.opt1, opt2 = s.opt2 }) end
    end

    local specQueues = {}
    for _, d in ipairs(desired) do
        specQueues[d.class] = specQueues[d.class] or {}
        table.insert(specQueues[d.class], d)
    end

    local whispered = {}
    for _, m in ipairs(bots) do
        local short = UNIT_TO_SHORT[m.class]
        if short and specQueues[short] and #specQueues[short] > 0 then
            local data = table.remove(specQueues[short], 1)
            SendChatMessage("talents spec "..data.spec.." pve", "WHISPER", nil, m.name)
            if data.opt1 and data.opt1 ~= "none" then
                if short == "Shaman" then
                    SendChatMessage("nc totems "..data.opt1, "WHISPER", nil, m.name)
                else
                    SendChatMessage("nc +"..(STRAT_MAP[data.opt1] or data.opt1), "WHISPER", nil, m.name)
                end
            end
            if data.opt2 and data.opt2 ~= "none" then
                SendChatMessage("nc +"..(STRAT_MAP[data.opt2] or data.opt2), "WHISPER", nil, m.name)
            end
            table.insert(whispered, m.name)
        end
    end
    return whispered
end

local function PushSpecs(comp)
    if not comp or not comp.slots then return end
    print("|cff00ff00[ORC] Pushing spec commands...|r")
    local whispered = WhisperCompSpecs(comp)
    print("|cff00ff00[ORC] Spec/Buff whispers sent to " .. #whispered .. " bots.|r")
end

local function PushSingleSpec(slotIndex)
    local slot = slots[slotIndex]
    if not slot or slot.isPlayer then return end

    local occurrence = 0
    for i = 1, slotIndex do
        if not slots[i].isPlayer and slots[i].class == slot.class then occurrence = occurrence + 1 end
    end

    local members = GetPartyMembers()
    local playerName = UnitName("player")
    local foundCount, targetName = 0, nil

    for _, m in ipairs(members) do
        if m.name ~= playerName and UNIT_TO_SHORT[m.class] == slot.class then
            foundCount = foundCount + 1
            if foundCount == occurrence then targetName = m.name; break end
        end
    end

    if targetName then
        SendChatMessage("talents spec "..slot.spec.." pve", "WHISPER", nil, targetName)
        if slot.opt1 and slot.opt1 ~= "none" then
            if slot.class == "Shaman" then 
                SendChatMessage("nc totems "..slot.opt1, "WHISPER", nil, targetName)
            else 
                local cmd = STRAT_MAP[slot.opt1] or slot.opt1
                SendChatMessage("nc +"..cmd, "WHISPER", nil, targetName) 
            end
        end
        if slot.opt2 and slot.opt2 ~= "none" then 
            local cmd = STRAT_MAP[slot.opt2] or slot.opt2
            SendChatMessage("nc +"..cmd, "WHISPER", nil, targetName) 
        end
        print("|cff00ff00[ORC] Respec sent to " .. targetName .. " (" .. slot.spec .. ")|r")
    else
        print("|cffff0000[ORC] Could not find matching " .. slot.class .. " in party for row " .. slotIndex .. ".|r")
    end
end

local function CheckRoster(comp)
    if not comp or not comp.slots then return end
    local members = GetPartyMembers()
    local playerName = UnitName("player")
    local bots = {}
    for _, m in ipairs(members) do if m.name ~= playerName then table.insert(bots, m) end end
    
    local desired = {}
    for i = 1, OptimalRaidCompDB.raidSize do
        local s = comp.slots[i]
        if s and not s.isPlayer then table.insert(desired, { class = s.class, spec = s.spec, matched = false }) end
    end
    
    local extraBots = {}
    for _, bot in ipairs(bots) do
        local shortClass = UNIT_TO_SHORT[bot.class]
        local matched = false
        for _, d in ipairs(desired) do
            if not d.matched and d.class == shortClass then d.matched = true; matched = true; break end
        end
        if not matched then table.insert(extraBots, { name = bot.name, class = shortClass or bot.class }) end
    end
    
    print("|cff00ffff[ORC] Roster Check ("..#bots.." bots):|r")
    local allGood = true
    for _, d in ipairs(desired) do
        if not d.matched then print("|cffff0000Missing Slot: " .. d.class .. " (" .. d.spec .. ")|r"); allGood = false end
    end
    for _, e in ipairs(extraBots) do
        print("|cffffff00Extra Bot: " .. e.name .. " (" .. e.class .. ")|r"); allGood = false
    end
    if allGood then print("|cff00ff00Roster perfectly matches template!|r") end
end

local function SummonComp(comp)
    if not comp or not comp.slots then return end
    if activeSummonFrame then activeSummonFrame:Hide() end
    
    print("|cff00ff00[ORC] Initializing summon sequence...|r")
    local playerName = UnitName("player")
    local desired = {}
    for i = 1, OptimalRaidCompDB.raidSize do
        local s = comp.slots[i]
        if s and not s.isPlayer then table.insert(desired, { class = s.class, spec = s.spec, opt1 = s.opt1, opt2 = s.opt2 }) end
    end

    local function StartSummoning()
        local idx = 1
        local lastTime, timeoutStart = GetTime(), GetTime()
        local expectedSize = 1
        local phase = 1 
        
        activeSummonFrame = CreateFrame("Frame")
        activeSummonFrame:SetScript("OnUpdate", function(self)
            local now = GetTime()
            local currentSize = 1
            if GetNumRaidMembers() > 0 then currentSize = GetNumRaidMembers()
            elseif GetNumPartyMembers() > 0 then currentSize = GetNumPartyMembers() + 1 end

            if phase == 1 then
                if #desired > 0 then
                    local cmd = CLASS_TO_CMD[desired[1].class]
                    if cmd then SendChatMessage(".warstormbot bot addclass "..cmd, "SAY") end
                    expectedSize = 2; lastTime = now; timeoutStart = now; idx = 2
                end
                if OptimalRaidCompDB.raidSize > 5 then
                    phase = 2; print("|cffffff00[ORC] Waiting for 1st bot to join...|r")
                else phase = 4 end
            elseif phase == 2 then
                if currentSize >= 2 then
                    ConvertToRaid(); print("|cffffff00[ORC] Converting to Raid...|r"); lastTime = now; timeoutStart = now; phase = 3
                elseif now - timeoutStart > 10 then
                    print("|cffff0000[ORC] Timeout waiting for 1st bot. Proceeding...|r"); phase = 3
                end
            elseif phase == 3 then
                if GetNumRaidMembers() > 0 then
                    print("|cff00ff00[ORC] Raid formed! Resuming mass summons.|r"); lastTime = now; timeoutStart = now; phase = 4
                elseif now - timeoutStart > 10 then
                    print("|cffff0000[ORC] Timeout waiting for raid conversion. Proceeding...|r"); phase = 4
                end
            elseif phase == 4 then
                if currentSize < expectedSize then
                    if now - timeoutStart > 8 then
                        print("|cffff0000[ORC] Warning: Bot missed invite or server lag. Proceeding...|r")
                        expectedSize = currentSize; lastTime = now; timeoutStart = now
                    end
                else
                    if now - lastTime >= 1.0 then
                        if idx <= #desired then
                            local cmd = CLASS_TO_CMD[desired[idx].class]
                            if cmd then SendChatMessage(".warstormbot bot addclass "..cmd, "SAY") end
                            expectedSize = currentSize + 1; lastTime = now; timeoutStart = now; idx = idx + 1
                        else
                            self:SetScript("OnUpdate", nil)
                            print("|cffffff00[ORC] Summons finished. 5s until init/specs...|r")
                            local waitStart = GetTime()
                            self:SetScript("OnUpdate", function(waitSelf)
                                if GetTime() - waitStart >= 5 then waitSelf:SetScript("OnUpdate", nil); self.Finalize() end
                            end)
                        end
                    end
                end
            end
        end)

        activeSummonFrame.Finalize = function()
            local members, isRaid = GetPartyMembers()
            local bots = {}
            for _, m in ipairs(members) do if m.name ~= playerName then table.insert(bots, m) end end
            
            local specQueues = {}
            for _, d in ipairs(desired) do
                specQueues[d.class] = specQueues[d.class] or {}
                table.insert(specQueues[d.class], d)
            end

            local toProcess = {}
            for _, m in ipairs(bots) do
                local short = UNIT_TO_SHORT[m.class]
                if short and specQueues[short] and #specQueues[short] > 0 then
                    local data = table.remove(specQueues[short], 1)
                    table.insert(toProcess, { name = m.name, spec = data.spec, opt1 = data.opt1, opt2 = data.opt2, class = short })
                end
            end

            local iIdx = 1
            activeSummonFrame:SetScript("OnUpdate", function(it)
                if iIdx > #toProcess then
                    it:SetScript("OnUpdate", nil)
                    activeSummonFrame = nil   -- summon loop done; follow-ups run on the scheduler

                    local whispered = {}
                    for _, tp in ipairs(toProcess) do
                        SendChatMessage("talents spec "..tp.spec.." pve", "WHISPER", nil, tp.name)
                        if tp.opt1 and tp.opt1 ~= "none" then
                            if tp.class == "Shaman" then
                                SendChatMessage("nc totems "..tp.opt1, "WHISPER", nil, tp.name)
                            else
                                SendChatMessage("nc +"..(STRAT_MAP[tp.opt1] or tp.opt1), "WHISPER", nil, tp.name)
                            end
                        end
                        if tp.opt2 and tp.opt2 ~= "none" then
                            SendChatMessage("nc +"..(STRAT_MAP[tp.opt2] or tp.opt2), "WHISPER", nil, tp.name)
                        end
                        table.insert(whispered, tp.name)
                    end
                    print("|cffffff00[ORC] Specs pushed. Waiting for bot confirmations...|r")
                    SetGroupLoot()

                    -- Gear once every bot confirms its spec (or after the 6s timeout,
                    -- with a warning) so autogear can't race a not-yet-switched bot.
                    AwaitSpecConfirms(whispered, 6, function(allOk, missing)
                        if not allOk then WarnSpecMissing(missing) end
                        SendChatMessage("autogear", isRaid and "RAID" or "PARTY")
                        print("|cff00ff00[ORC] Autogear sent. World Buffs in 2s...|r")
                        After(2, function()
                            SendChatMessage("nc +worldbuff", isRaid and "RAID" or "PARTY")
                            print("|cff00ff00[ORC] World Buffs sent! Setup Complete!|r")
                            if isRaid then SortRaidGroup(comp) end
                        end)
                    end)
                else
                    SendChatMessage(".warstormbot bot init=epic "..toProcess[iIdx].name, "SAY")
                    iIdx = iIdx + 1
                end
            end)
        end
    end

    SendChatMessage(".warstormbot bot remove *", "SAY")
    local watchFrame = CreateFrame("Frame")
    activeSummonFrame = watchFrame -- so STOP works during the cleanup wait too
    local wStart = GetTime()
    watchFrame:SetScript("OnUpdate", function(self)
        local members, _ = GetPartyMembers()
        if #members <= 1 or (GetTime() - wStart > 5) then self:SetScript("OnUpdate", nil); self:Hide(); StartSummoning() end
    end)
end

-- ==================== POPUPS & SAFETY ====================
StaticPopupDialogs["ORC_CONFIRM_SUMMON"] = {
    text = "You are currently in a group or raid. Creating a new group will remove all current bots. Proceed?",
    button1 = "Yes", button2 = "No",
    OnAccept = function(self, data) SummonComp(data) end,
    timeout = 0, whileDead = 1, hideOnEscape = 1
}

local function SafeSummon(comp)
    if GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 then StaticPopup_Show("ORC_CONFIRM_SUMMON", nil, nil, comp)
    else SummonComp(comp) end
end

-- Re-init the current bots: per-bot `.warstormbot bot init=epic <Name>` to SAY, then
-- re-apply the comp's specs (confirm-gated) and autogear. init=epic is rejected in
-- combat, so when in combat we flag it and the PLAYER_REGEN_ENABLED handler retries
-- 3s after combat ends (in case a bot lingers in combat slightly longer than us).
local function ReinitBots(comp)
    local members, isRaid = GetPartyMembers()
    local playerName = UnitName("player")
    local bots = {}
    for _, m in ipairs(members) do if m.name ~= playerName then table.insert(bots, m) end end
    if #bots == 0 then print("|cffff0000[ORC] No bots in the group to re-init.|r"); return end

    if UnitAffectingCombat("player") then
        reinitPending = true; pendingReinitComp = comp
        print("|cffffff00[ORC] In combat -- bots will re-init 3s after combat ends.|r")
        return
    end
    reinitPending = false

    print("|cff00ff00[ORC] Re-initializing "..#bots.." bots...|r")
    for _, m in ipairs(bots) do
        SendChatMessage(".warstormbot bot init=epic "..m.name, "SAY")
    end
    After(3, function()
        if comp and comp.slots then
            local whispered = WhisperCompSpecs(comp)
            AwaitSpecConfirms(whispered, 6, function(allOk, missing)
                if not allOk then WarnSpecMissing(missing) end
                SendChatMessage("autogear", isRaid and "RAID" or "PARTY")
                print("|cff00ff00[ORC] Bots re-initialized (autogear sent).|r")
            end)
        else
            SendChatMessage("autogear", isRaid and "RAID" or "PARTY")
            print("|cff00ff00[ORC] Bots re-initialized.|r")
        end
    end)
end

-- ==================== TRADE PAYOUT ====================
-- Warstorm bots buy green-or-better items you trade them, paying ~3x the items'
-- vendor value. As soon as you place/change items in the trade window this whispers
-- the partner the payout (3 x summed vendor sell value of the uncommon+ items on
-- offer, excluding locked/unlockable containers). 3.3.5a's GetItemInfo returns no
-- sell price, so value is read from a hidden tooltip's money frame. Toggle with
-- /orc tradewhisper; verify the numbers with /orc tradevalue.
local TRADE_SLOTS = 6   -- slots 1..6 are tradeable; slot 7 is the no-trade slot
local tradeScanTip
local function EnsureScanTip()
    if not tradeScanTip then
        tradeScanTip = CreateFrame("GameTooltip", "ORC_TradeScanTip", UIParent, "GameTooltipTemplate")
    end
    return tradeScanTip
end

local function ScanTipSellValue()
    local mf = _G["ORC_TradeScanTipMoneyFrame1"]
    if not mf or not mf:IsShown() then return 0 end
    local function part(suffix)
        local b = _G["ORC_TradeScanTipMoneyFrame1" .. suffix]
        return tonumber(b and b:GetText()) or 0
    end
    return part("GoldButton") * 10000 + part("SilverButton") * 100 + part("CopperButton")
end

local function ScanTipLocked()
    for i = 1, (tradeScanTip:NumLines() or 0) do
        local fs = _G["ORC_TradeScanTipTextLeft" .. i]
        local txt = fs and fs:GetText()
        if txt and string.find(txt, LOCKED, 1, true) then return true end
    end
    return false
end

-- Format copper as "<g>g<s>s<c>c", omitting zero components. nil for non-positive.
local function FormatPayout(copper)
    if not copper or copper <= 0 then return nil end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local msg = ""
    if g > 0 then msg = msg .. g .. "g" end
    if s > 0 then msg = msg .. s .. "s" end
    if c > 0 then msg = msg .. c .. "c" end
    return msg
end

-- Sum vendor value of uncommon+ non-locked offered items. Returns (copper, count,
-- pending) -- pending=true when an item isn't cached yet so the caller can retry.
local function ComputeOfferedVendorValue()
    local tip = EnsureScanTip()
    local total, count, pending = 0, 0, false
    for i = 1, TRADE_SLOTS do
        local link = GetTradePlayerItemLink(i)
        if link then
            local _, _, quality = GetItemInfo(link)
            if not quality then
                pending = true
            elseif quality >= 2 then
                local stale = _G["ORC_TradeScanTipMoneyFrame1"]
                if stale then stale:Hide() end
                tip:SetOwner(UIParent, "ANCHOR_NONE")
                tip:ClearLines()
                tip:SetTradePlayerItem(i)
                if not ScanTipLocked() then
                    local v = ScanTipSellValue()
                    if v > 0 then total = total + v; count = count + 1 end
                end
            end
        end
    end
    return total, count, pending
end

local function TradePartnerName()
    local n = UnitName("NPC")
    if n and n ~= "" and n ~= UNKNOWN then return n end
    if TradeFrameRecipientNameText then
        local t = TradeFrameRecipientNameText:GetText()
        if t and t ~= "" then return t end
    end
    return nil
end

local tradeDebounceToken
local lastTradePayoutMsg

local function WhisperTradePayout()
    if OptimalRaidCompDB.tradeWhisper == false then return end
    local partner = TradePartnerName()
    if not partner then return end
    local total, count = ComputeOfferedVendorValue()
    local msg = FormatPayout(total * 3)
    if not msg then lastTradePayoutMsg = nil; return end   -- offer empty: let a re-add re-whisper
    if msg == lastTradePayoutMsg then return end
    lastTradePayoutMsg = msg
    SendChatMessage(msg, "WHISPER", nil, partner)
    print("|cff00ff00[ORC] trade payout -> "..partner..": "..msg.." (3x vendor of "..count.." item(s)).|r")
end

-- Print the current offer's payout without whispering (/orc tradevalue).
local function PrintTradeValue()
    local total, count = ComputeOfferedVendorValue()
    local msg = FormatPayout(total * 3) or "0c"
    print("|cff00ffff[ORC] trade value: "..msg.." (3x vendor of "..count.." item(s)).|r")
end

-- Debounce the per-slot TRADE_PLAYER_ITEM_CHANGED burst; retry while items load.
local function ScheduleTradeWhisper(attempt)
    attempt = attempt or 1
    local token = {}
    tradeDebounceToken = token
    After(0.4, function()
        if tradeDebounceToken ~= token then return end
        local _, _, pending = ComputeOfferedVendorValue()
        if pending and attempt < 5 then ScheduleTradeWhisper(attempt + 1)
        else WhisperTradePayout() end
    end)
end

local tradeFrame = CreateFrame("Frame")
tradeFrame:RegisterEvent("TRADE_SHOW")
tradeFrame:RegisterEvent("TRADE_CLOSED")
tradeFrame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
tradeFrame:SetScript("OnEvent", function(self, event)
    if event == "TRADE_PLAYER_ITEM_CHANGED" then ScheduleTradeWhisper()
    else lastTradePayoutMsg = nil end
end)

-- ==================== GUI ====================
local frame = CreateFrame("Frame", "OptimalRaidCompFrame", UIParent)
frame:SetSize(700, 490)
frame:SetPoint("CENTER"); frame:SetMovable(true); frame:EnableMouse(true); frame:EnableMouseWheel(true); frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving); frame:SetScript("OnDragStop", frame.StopMovingOrSizing); frame:Hide()

tinsert(UISpecialFrames, "OptimalRaidCompFrame")

frame:SetScript("OnMouseWheel", function(self, delta)
    local s = (OptimalRaidCompDB.scale or 1.0) + (delta * 0.05)
    OptimalRaidCompDB.scale = math.max(0.5, math.min(2.0, s))
    self:SetScale(OptimalRaidCompDB.scale)
end)

frame:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11, right=12, top=12, bottom=11}})
frame:SetBackdropColor(0,0,0,1)

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -15); title:SetText("Optimal Raid Comp Manager")

local scrollContainer = CreateFrame("Frame", nil, frame); scrollContainer:SetPoint("TOPLEFT", 15, -70); scrollContainer:SetPoint("BOTTOMRIGHT", -35, 120)
local fauxScroll = CreateFrame("ScrollFrame", "OptimalRaidCompFauxScroll", scrollContainer, "FauxScrollFrameTemplate")
fauxScroll:SetPoint("TOPLEFT", 0, 0); fauxScroll:SetPoint("BOTTOMRIGHT", -25, 0)

slots = {}
for i = 1, MAX_ROWS do slots[i] = { class = "Warrior", spec = "prot", opt1 = "none", opt2 = "none", isPlayer = false } end

local visibleRows = {}
local function UpdateVisibleRows()
    local offset = FauxScrollFrame_GetOffset(fauxScroll)
    for i = 1, VISIBLE_ROWS do
        local idx = i + offset
        local row = visibleRows[i]
        if idx > OptimalRaidCompDB.raidSize then row.frame:Hide() else
            row.frame:Show(); row.num:SetText(idx..":")
            UIDropDownMenu_SetText(row.classDD, slots[idx].class)
            UIDropDownMenu_SetText(row.specDD, slots[idx].spec)
            
            local o1, o2 = GetOptionsForClassSpec(slots[idx].class, slots[idx].spec)
            
            if o1 then 
                row.opt1DD:Show()
                UIDropDownMenu_SetText(row.opt1DD, slots[idx].opt1 or "none")
            else row.opt1DD:Hide() end
            
            if o2 then 
                row.opt2DD:Show()
                UIDropDownMenu_SetText(row.opt2DD, slots[idx].opt2 or "none")
            else row.opt2DD:Hide() end

            row.playerCheck:SetChecked(slots[idx].isPlayer)
            if slots[idx].isPlayer then row.specBtn:Hide() else row.specBtn:Show() end
        end
    end
    FauxScrollFrame_Update(fauxScroll, OptimalRaidCompDB.raidSize, VISIBLE_ROWS, ROW_HEIGHT)
end

for i = 1, VISIBLE_ROWS do
    local r = CreateFrame("Frame", nil, scrollContainer); r:SetSize(650, ROW_HEIGHT)
    if i == 1 then r:SetPoint("TOPLEFT", 0, 0) else r:SetPoint("TOP", visibleRows[i-1].frame, "BOTTOM", 0, 0) end
    local n = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); n:SetPoint("LEFT", 0, 0)
    
    local cDD = CreateFrame("Frame", "ORC_CDD"..i, r, "UIDropDownMenuTemplate"); cDD:SetPoint("LEFT", 15, -2); UIDropDownMenu_SetWidth(cDD, 90)
    local sDD = CreateFrame("Frame", "ORC_SDD"..i, r, "UIDropDownMenuTemplate"); sDD:SetPoint("LEFT", 125, -2); UIDropDownMenu_SetWidth(sDD, 80)
    local o1DD = CreateFrame("Frame", "ORC_O1DD"..i, r, "UIDropDownMenuTemplate"); o1DD:SetPoint("LEFT", 225, -2); UIDropDownMenu_SetWidth(o1DD, 90)
    local o2DD = CreateFrame("Frame", "ORC_O2DD"..i, r, "UIDropDownMenuTemplate"); o2DD:SetPoint("LEFT", 335, -2); UIDropDownMenu_SetWidth(o2DD, 90)
    
    local pCT = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); pCT:SetPoint("LEFT", 460, 0); pCT:SetText("Player:")
    local pC = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate"); pC:SetPoint("LEFT", pCT, "RIGHT", 5, 0); pC:SetScale(0.85)
    local sBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate"); sBtn:SetSize(45, 20); sBtn:SetPoint("LEFT", pC, "RIGHT", 15, 0); sBtn:SetText("Spec")
    
    visibleRows[i] = { frame = r, num = n, classDD = cDD, specDD = sDD, opt1DD = o1DD, opt2DD = o2DD, playerCheck = pC, specBtn = sBtn, index = i }
    
    UIDropDownMenu_Initialize(cDD, function()
        for _, c in ipairs(classes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = c
            info.func = function()
                local idx = i + FauxScrollFrame_GetOffset(fauxScroll)
                slots[idx].class = c; slots[idx].spec = specsByClass[c][1]
                slots[idx].opt1 = "none"; slots[idx].opt2 = "none"
                UpdateVisibleRows()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    UIDropDownMenu_Initialize(sDD, function()
        local idx = i + FauxScrollFrame_GetOffset(fauxScroll)
        for _, s in ipairs(specsByClass[slots[idx].class] or {"none"}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s
            info.func = function() 
                slots[idx].spec = s
                if slots[idx].class == "Paladin" and s ~= "prot" and slots[idx].opt1 == "sanctuary" then slots[idx].opt1 = "none" end
                UpdateVisibleRows() 
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    UIDropDownMenu_Initialize(o1DD, function()
        local idx = i + FauxScrollFrame_GetOffset(fauxScroll)
        local o1List, _ = GetOptionsForClassSpec(slots[idx].class, slots[idx].spec)
        if not o1List then return end
        
        local info = UIDropDownMenu_CreateInfo(); info.text = "none"
        info.func = function() slots[idx].opt1 = "none"; UpdateVisibleRows() end
        UIDropDownMenu_AddButton(info)
        
        for _, o in ipairs(o1List) do
            local info = UIDropDownMenu_CreateInfo(); info.text = o
            info.func = function() slots[idx].opt1 = o; UpdateVisibleRows() end
            
            -- Tooltip Logic for Shamans
            if slots[idx].class == "Shaman" and TOTEM_TOOLTIPS[o] then
                info.tooltipTitle = o:gsub("^%l", string.upper) .. " Totem Set"
                info.tooltipText = TOTEM_TOOLTIPS[o]
                info.tooltipOnButton = 1
            end
            
            UIDropDownMenu_AddButton(info)
        end
    end)

    UIDropDownMenu_Initialize(o2DD, function()
        local idx = i + FauxScrollFrame_GetOffset(fauxScroll)
        local _, o2List = GetOptionsForClassSpec(slots[idx].class, slots[idx].spec)
        if not o2List then return end
        
        local info = UIDropDownMenu_CreateInfo(); info.text = "none"
        info.func = function() slots[idx].opt2 = "none"; UpdateVisibleRows() end
        UIDropDownMenu_AddButton(info)

        for _, o in ipairs(o2List) do
            local info = UIDropDownMenu_CreateInfo(); info.text = o
            info.func = function() slots[idx].opt2 = o; UpdateVisibleRows() end
            UIDropDownMenu_AddButton(info)
        end
    end)

    pC:SetScript("OnClick", function(self) slots[i + FauxScrollFrame_GetOffset(fauxScroll)].isPlayer = self:GetChecked(); UpdateVisibleRows() end)
    sBtn:SetScript("OnClick", function() PushSingleSpec(i + FauxScrollFrame_GetOffset(fauxScroll)) end)
end

fauxScroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateVisibleRows) end)

-- ==================== BOTTOM CONTROLS ====================
local sizeLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sizeLabel:SetPoint("BOTTOMLEFT", 20, 90); sizeLabel:SetText("Size:")
local sizeDD = CreateFrame("Frame", "ORC_SizeDD", frame, "UIDropDownMenuTemplate")
sizeDD:SetPoint("LEFT", sizeLabel, "RIGHT", -5, -2); UIDropDownMenu_SetWidth(sizeDD, 80)

local compLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
compLabel:SetPoint("BOTTOMLEFT", 20, 55); compLabel:SetText("Profile:")
local compDD = CreateFrame("Frame", "ORC_MainCompDD", frame, "UIDropDownMenuTemplate")
compDD:SetPoint("LEFT", compLabel, "RIGHT", -15, -2); UIDropDownMenu_SetWidth(compDD, 120)

local saveBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); saveBtn:SetSize(50, 22); saveBtn:SetPoint("LEFT", compDD, "RIGHT", -10, 2); saveBtn:SetText("Save")
local saveAsBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); saveAsBtn:SetSize(62, 22); saveAsBtn:SetPoint("LEFT", saveBtn, "RIGHT", 5, 0); saveAsBtn:SetText("Save As")
local renBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); renBtn:SetSize(62, 22); renBtn:SetPoint("LEFT", saveAsBtn, "RIGHT", 5, 0); renBtn:SetText("Rename")
local delBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); delBtn:SetSize(55, 22); delBtn:SetPoint("LEFT", renBtn, "RIGHT", 5, 0); delBtn:SetText("Delete")

-- LIVE ACTION BUTTONS
local checkBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); checkBtn:SetSize(60, 22); checkBtn:SetPoint("BOTTOMLEFT", 15, 20); checkBtn:SetText("Roster")
checkBtn:SetScript("OnClick", function()
    local temp = { slots = {} }
    for j=1, MAX_ROWS do temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, isPlayer=slots[j].isPlayer } end
    CheckRoster(temp)
end)

local zoneBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); zoneBtn:SetSize(60, 22); zoneBtn:SetPoint("LEFT", checkBtn, "RIGHT", 5, 0); zoneBtn:SetText("Zone")
zoneBtn:SetScript("OnClick", function() CheckInstance() end)

local pushSpecBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); pushSpecBtn:SetSize(60, 22); pushSpecBtn:SetPoint("LEFT", zoneBtn, "RIGHT", 5, 0); pushSpecBtn:SetText("Specs")
pushSpecBtn:SetScript("OnClick", function()
    local temp = { slots = {} }
    for j=1, MAX_ROWS do temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer } end
    PushSpecs(temp)
end)

local pushGearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); pushGearBtn:SetSize(60, 22); pushGearBtn:SetPoint("LEFT", pushSpecBtn, "RIGHT", 5, 0); pushGearBtn:SetText("Gear")
pushGearBtn:SetScript("OnClick", function() PushAutogear() end)

local pushBuffBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); pushBuffBtn:SetSize(60, 22); pushBuffBtn:SetPoint("LEFT", pushGearBtn, "RIGHT", 5, 0); pushBuffBtn:SetText("Buffs")
pushBuffBtn:SetScript("OnClick", function() PushWorldBuffs() end)

local sortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); sortBtn:SetSize(60, 22); sortBtn:SetPoint("LEFT", pushBuffBtn, "RIGHT", 5, 0); sortBtn:SetText("Sort")
sortBtn:SetScript("OnClick", function()
    local temp = { slots = {} }
    for j=1, MAX_ROWS do temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, isPlayer=slots[j].isPlayer } end
    SortRaidGroup(temp)
end)

local summonBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); summonBtn:SetSize(75, 22); summonBtn:SetPoint("LEFT", sortBtn, "RIGHT", 5, 0); summonBtn:SetText("Create")
summonBtn:SetScript("OnClick", function()
    local temp = { slots = {} }
    for j=1, MAX_ROWS do temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer } end
    SafeSummon(temp); frame:Hide()
end)

-- DROPDOWN LOGIC
local function RefreshCompList()
    UIDropDownMenu_Initialize(compDD, function()
        for name, data in pairs(OptimalRaidCompDB.comps) do
            local cSize = data.size or 25

            if cSize == OptimalRaidCompDB.raidSize then
                local info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.func = function()
                    OptimalRaidCompDB.currentComp = name; UIDropDownMenu_SetText(compDD, name)
                    for j=1, MAX_ROWS do 
                        if data.slots[j] then slots[j] = { class = data.slots[j].class, spec = data.slots[j].spec, opt1 = data.slots[j].opt1 or "none", opt2 = data.slots[j].opt2 or "none", isPlayer = data.slots[j].isPlayer } end
                    end
                    UpdateVisibleRows()
                end
                UIDropDownMenu_AddButton(info)
            end
        end
    end)
    
    local currData = OptimalRaidCompDB.currentComp and OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp]
    local currSize = currData and (currData.size or 25)
    if currSize == OptimalRaidCompDB.raidSize then UIDropDownMenu_SetText(compDD, OptimalRaidCompDB.currentComp)
    else UIDropDownMenu_SetText(compDD, "Select Profile"); OptimalRaidCompDB.currentComp = nil end
end

local function RefreshSizeDD()
    UIDropDownMenu_Initialize(sizeDD, function()
        local sizes = {5, 10, 25}
        for _, s in ipairs(sizes) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = s .. "-Man"
            info.func = function()
                OptimalRaidCompDB.raidSize = s; UIDropDownMenu_SetText(sizeDD, s .. "-Man"); 
                RefreshCompList(); UpdateVisibleRows()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText(sizeDD, (OptimalRaidCompDB.raidSize or 25) .. "-Man")
end

-- Save the current rows into a profile (new one or overwriting an existing one).
local function SaveCurrentToProfile(name)
    if not name or name == "" then return end
    OptimalRaidCompDB.comps[name] = { size = OptimalRaidCompDB.raidSize, slots = {} }
    for j=1, MAX_ROWS do
        OptimalRaidCompDB.comps[name].slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer }
    end
    OptimalRaidCompDB.currentComp = name
    RefreshCompList(); UIDropDownMenu_SetText(ORC_MainCompDD, name)
    print("|cff00ff00[ORC] Profile saved: " .. name .. "|r")
end

-- POPUP DEFINITIONS
StaticPopupDialogs["ORC_SAVE_NEW"] = {
    text = "Name your new template:", button1 = "Save", button2 = "Cancel", hasEditBox = 1,
    OnShow = function(self) self.editBox:SetText("Comp " .. math.random(100, 999)); self.editBox:HighlightText() end,
    OnAccept = function(self) SaveCurrentToProfile(self.editBox:GetText()) end,
    EditBoxOnEnterPressed = function(self) self:GetParent().button1:Click() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1
}

StaticPopupDialogs["ORC_OVERWRITE"] = {
    text = "Overwrite profile \"%s\" with the current layout?",
    button1 = "Overwrite", button2 = "Cancel",
    OnAccept = function(self, data) SaveCurrentToProfile(data) end,
    timeout = 0, whileDead = 1, hideOnEscape = 1
}

StaticPopupDialogs["ORC_RENAME"] = { text = "Rename Template:", button1 = "Rename", button2 = "Cancel", hasEditBox = 1, OnAccept = function(self) local new = self.editBox:GetText(); if new ~= "" and OptimalRaidCompDB.currentComp then OptimalRaidCompDB.comps[new] = OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp]; OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] = nil; OptimalRaidCompDB.currentComp = new; RefreshCompList() end end, timeout = 0, whileDead = 1, hideOnEscape = 1 }

saveBtn:SetScript("OnClick", function()
    local cur = OptimalRaidCompDB.currentComp
    if cur and OptimalRaidCompDB.comps[cur] then
        StaticPopup_Show("ORC_OVERWRITE", cur, nil, cur)
    else
        StaticPopup_Show("ORC_SAVE_NEW")
    end
end)
saveAsBtn:SetScript("OnClick", function() StaticPopup_Show("ORC_SAVE_NEW") end)
renBtn:SetScript("OnClick", function() if OptimalRaidCompDB.currentComp then StaticPopup_Show("ORC_RENAME") end end)
delBtn:SetScript("OnClick", function()
    if OptimalRaidCompDB.currentComp then OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] = nil; OptimalRaidCompDB.currentComp = nil; UIDropDownMenu_SetText(compDD, "Select Profile"); RefreshCompList() end
end)

-- ==================== BOT CONTROL ====================
local controlButtons, controlChecks = {}, {}
local cmdWin, cmdClose      -- floating Commands window + its close button
local RefreshControlLayout

do
    local function CBtn(parent, text, w, h)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w, h); b:SetText(text)
        table.insert(controlButtons, b)
        return b
    end

    ------------------------------------------------------------------
    -- Main-window controls: a top row (formation + reinit/loot + the button
    -- that opens the Commands window) and the two toggles on the size row.
    ------------------------------------------------------------------
    local formLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    formLabel:SetPoint("TOPLEFT", 18, -46); formLabel:SetText("Formation:")
    local prevBtn  = CBtn(frame, "<", 24, 22);         prevBtn:SetPoint("TOPLEFT", 88, -44)
    local formText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    formText:SetPoint("TOPLEFT", 114, -47); formText:SetWidth(88); formText:SetJustifyH("CENTER")
    local nextBtn   = CBtn(frame, ">", 24, 22);        nextBtn:SetPoint("TOPLEFT", 206, -44)
    local setForm   = CBtn(frame, "Set", 44, 22);      setForm:SetPoint("TOPLEFT", 234, -44)
    local checkForm = CBtn(frame, "Check", 52, 22);    checkForm:SetPoint("TOPLEFT", 280, -44)
    local reinitBtn = CBtn(frame, "Reinit", 60, 22);   reinitBtn:SetPoint("TOPLEFT", 344, -44)
    local lootBtn   = CBtn(frame, "Loot FFA", 70, 22); lootBtn:SetPoint("TOPLEFT", 406, -44)
    local cmdBtn    = CBtn(frame, "Commands", 90, 22); cmdBtn:SetPoint("TOPLEFT", 480, -44)

    local function SetFormText() formText:SetText(OptimalRaidCompDB.selectedFormation or formations[1].name) end
    local function CycleFormation(step)
        local i = ((OptimalRaidCompDB.selectedFormationIndex or 1) - 1 + step) % #formations + 1
        OptimalRaidCompDB.selectedFormationIndex = i
        OptimalRaidCompDB.selectedFormation = formations[i].name
        SetFormText()
    end
    prevBtn:SetScript("OnClick", function() CycleFormation(-1) end)
    nextBtn:SetScript("OnClick", function() CycleFormation(1) end)
    setForm:SetScript("OnClick", function()
        SendBotOrder("formation "..formations[OptimalRaidCompDB.selectedFormationIndex or 1].command)
    end)
    checkForm:SetScript("OnClick", function() SendBotOrder("formation") end)
    SetFormText()
    reinitBtn:SetScript("OnClick", function() ReinitBots(BuildCompFromSlots()) end)
    lootBtn:SetScript("OnClick", function() SetGroupLoot() end)

    -- Two toggles, parked on the right of the size row.
    local function CChk(parent, label, px, py, getv, setv)
        local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        c:SetSize(24, 24); c:SetPoint("BOTTOMLEFT", px, py); c:SetChecked(getv())
        local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("LEFT", c, "RIGHT", 2, 0); t:SetText(label)
        c:SetScript("OnClick", function(self) setv(self:GetChecked() and true or false) end)
        table.insert(controlChecks, c)
    end
    CChk(frame, "Auto-reinit on level up", 300, 88,
        function() return OptimalRaidCompDB.autoLevelUp end,
        function(v) OptimalRaidCompDB.autoLevelUp = v end)
    CChk(frame, "Trade payout whisper", 500, 88,
        function() return OptimalRaidCompDB.tradeWhisper end,
        function(v) OptimalRaidCompDB.tradeWhisper = v end)

    ------------------------------------------------------------------
    -- Floating Commands window: the behavior grid + footer actions. Movable
    -- and toggled by the main window's "Commands" button (like the launcher).
    ------------------------------------------------------------------
    cmdWin = CreateFrame("Frame", "ORC_CommandsWindow", UIParent)
    cmdWin:SetSize(360, 252)
    cmdWin:SetPoint("CENTER", OptimalRaidCompDB.cmdWinPos.x, OptimalRaidCompDB.cmdWinPos.y)
    cmdWin:SetMovable(true); cmdWin:EnableMouse(true); cmdWin:RegisterForDrag("LeftButton")
    cmdWin:SetScript("OnDragStart", cmdWin.StartMoving)
    cmdWin:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint()
        OptimalRaidCompDB.cmdWinPos = { x = x, y = y }
    end)
    cmdWin:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border", tile=true, tileSize=32, edgeSize=32, insets={left=11, right=12, top=12, bottom=11}})
    cmdWin:SetBackdropColor(0, 0, 0, 1)
    cmdWin:Hide()
    tinsert(UISpecialFrames, "ORC_CommandsWindow")

    cmdClose = CreateFrame("Button", nil, cmdWin, "UIPanelCloseButton"); cmdClose:SetPoint("TOPRIGHT", -4, -4)
    local cmdTitle = cmdWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cmdTitle:SetPoint("TOPLEFT", 14, -12); cmdTitle:SetText("ORC Commands")
    local moreBtn = CBtn(cmdWin, "More", 60, 20); moreBtn:SetPoint("TOPRIGHT", -28, -10)

    cmdBtn:SetScript("OnClick", function() if cmdWin:IsShown() then cmdWin:Hide() else cmdWin:Show() end end)

    -- Track the last order ORC sent each role so 'attack' can break a stay/flee lock
    -- by sending 'follow' first; a double-tap of attack within 1.5s forces the same
    -- reset manually (for locks ORC didn't set, e.g. via keybind or server flee).
    local lastOrder, lastAttackAt = {}, {}
    local function GridClick(role, action)
        local key = role.label
        if action == "attack" then
            local now = GetTime()
            local stuck = (lastOrder[key] == "stay" or lastOrder[key] == "flee")
            local doubleTap = lastAttackAt[key] and (now - lastAttackAt[key] < 1.5)
            if stuck or doubleTap then
                SendBotOrder(role.prefix.."follow")
                After(0.3, function() SendBotOrder(role.prefix.."attack") end)
            else
                SendBotOrder(role.prefix.."attack")
            end
            lastAttackAt[key] = now
        else
            SendBotOrder(role.prefix..action)
        end
        lastOrder[key] = action
    end

    local rowStart, rowH = -52, 26
    local controlRows = {}
    for r, role in ipairs(roles) do
        local rf = CreateFrame("Frame", nil, cmdWin)
        rf:SetSize(330, 24); rf:SetPoint("TOPLEFT", 14, rowStart - (r - 1) * rowH)
        local lbl = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", 0, 0); lbl:SetWidth(46); lbl:SetText(role.label)
        for c, action in ipairs(actions) do
            local b = CreateFrame("Button", nil, rf, "UIPanelButtonTemplate")
            b:SetSize(64, 22); b:SetPoint("LEFT", 50 + (c - 1) * 68, 0)
            b:SetText(action); b:SetNormalFontObject("GameFontNormalSmall")
            b:SetScript("OnClick", function() GridClick(role, action) end)
            table.insert(controlButtons, b)
        end
        controlRows[r] = rf
    end

    local cmdFooter = CreateFrame("Frame", nil, cmdWin); cmdFooter:SetSize(330, 24)
    for i, item in ipairs(footer) do
        local b = CBtn(cmdFooter, item.label, 58, 22)
        b:SetPoint("TOPLEFT", (i - 1) * 60, 0); b:SetNormalFontObject("GameFontNormalSmall")
        if item.command then
            local cmd = item.command
            b:SetScript("OnClick", function() SendBotOrder(cmd) end)
        elseif item.label == "Skull" then
            b:SetScript("OnClick", function() SendBotOrder("rti skull"); SendBotOrder("attack rti target") end)
        end
    end

    function RefreshControlLayout()
        local expanded = OptimalRaidCompDB.controlExpanded
        for r = 3, #roles do if expanded then controlRows[r]:Show() else controlRows[r]:Hide() end end
        local visRoles = expanded and #roles or 2
        local footerY = rowStart - visRoles * rowH - 10
        cmdFooter:ClearAllPoints()
        cmdFooter:SetPoint("TOPLEFT", cmdWin, "TOPLEFT", 14, footerY)
        cmdWin:SetHeight(math.abs(footerY) + 22 + 16)
        moreBtn:SetText(expanded and "Less" or "More")
    end
    moreBtn:SetScript("OnClick", function()
        OptimalRaidCompDB.controlExpanded = not OptimalRaidCompDB.controlExpanded
        RefreshControlLayout()
    end)
    RefreshControlLayout()
end

-- ==================== LAUNCHER ====================
local launch = CreateFrame("Button", "ORC_Launcher", UIParent)
launch:SetSize(110, 60); launch:SetPoint("CENTER", OptimalRaidCompDB.buttonPos.x, OptimalRaidCompDB.buttonPos.y)
launch:SetMovable(true); launch:EnableMouse(true); launch:RegisterForDrag("RightButton")
launch:SetBackdrop({bgFile="Interface\\ChatFrame\\ChatFrameBackground", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3, right=3, top=3, bottom=3}})
launch:SetBackdropColor(0,0,0,0.8); launch:SetBackdropBorderColor(0.7, 0.7, 0, 1)

launch.t = launch:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
launch.t:SetPoint("TOP", 0, -5); launch.t:SetText("|cffffcc00ORC|r")

local qs = CreateFrame("Button", nil, launch, "UIPanelButtonTemplate")
qs:SetSize(90, 18); qs:SetPoint("TOP", 0, -20); qs:SetText("Quick Create")
qs:SetNormalFontObject("GameFontNormalSmall")
qs:SetScript("OnClick", function()
    local temp = { slots = {} }
    for j=1, MAX_ROWS do temp.slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer } end
    SafeSummon(temp)
end)

local stopBtn = CreateFrame("Button", nil, launch, "UIPanelButtonTemplate")
stopBtn:SetSize(90, 18); stopBtn:SetPoint("TOP", qs, "BOTTOM", 0, -2); stopBtn:SetText("STOP Summon")
stopBtn:SetNormalFontObject("GameFontNormalSmall")
stopBtn:SetScript("OnClick", function()
    if activeSummonFrame then activeSummonFrame:Hide(); activeSummonFrame = nil; print("|cffff0000[ORC] Summoning ABORTED.|r") end
end)

launch:SetScript("OnClick", function(self, button) if button == "LeftButton" then if frame:IsShown() then frame:Hide() else frame:Show() end end end)
launch:SetScript("OnDragStart", function(self) self:StartMoving() end)
launch:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); local _, _, _, x, y = self:GetPoint(); OptimalRaidCompDB.buttonPos = { x = x, y = y } end)

-- ==================== ELVUI SKINNING ====================
-- Match the ElvUI look when it's installed. Wrapped in pcall so a skin error
-- can't stop the addon from loading; without ElvUI it just does nothing.
local elvSkinned = false
local function ApplyElvUISkin()
    if elvSkinned or not _G.ElvUI then return end

    local ok, err = pcall(function()
        local E = unpack(_G.ElvUI)
        if not E then return end
        local S = E:GetModule("Skins", true)
        if not S then return end

        local function btn(b) if b and S.HandleButton then S:HandleButton(b) end end
        local function dd(d)  if d and S.HandleDropDownBox then S:HandleDropDownBox(d) end end
        local function chk(c) if c and S.HandleCheckBox then S:HandleCheckBox(c) end end

        -- Main window
        if frame.StripTextures then frame:StripTextures() end
        if frame.SetTemplate then frame:SetTemplate("Transparent") end
        if closeBtn and S.HandleCloseButton then S:HandleCloseButton(closeBtn) end

        -- Per-row widgets
        for _, row in ipairs(visibleRows) do
            dd(row.classDD); dd(row.specDD); dd(row.opt1DD); dd(row.opt2DD)
            chk(row.playerCheck)
            btn(row.specBtn)
        end

        -- Bottom controls
        dd(sizeDD); dd(compDD)
        btn(saveBtn); btn(saveAsBtn); btn(renBtn); btn(delBtn)
        btn(checkBtn); btn(zoneBtn); btn(pushSpecBtn); btn(pushGearBtn)
        btn(pushBuffBtn); btn(sortBtn); btn(summonBtn)

        -- Bot control (formation/reinit/loot/commands + grid/footer buttons, toggles)
        for _, b in ipairs(controlButtons) do btn(b) end
        for _, c in ipairs(controlChecks) do chk(c) end
        if cmdWin then
            if cmdWin.StripTextures then cmdWin:StripTextures() end
            if cmdWin.SetTemplate then cmdWin:SetTemplate("Transparent") end
        end
        if cmdClose and S.HandleCloseButton then S:HandleCloseButton(cmdClose) end

        -- Scrollbar
        local sb = _G["OptimalRaidCompFauxScrollScrollBar"]
        if sb and S.HandleScrollBar then S:HandleScrollBar(sb) end

        -- Launcher
        if launch.StripTextures then launch:StripTextures() end
        if launch.SetTemplate then launch:SetTemplate("Transparent") end
        btn(qs); btn(stopBtn)
    end)

    if ok then
        elvSkinned = true
        print("|cff00ff00[ORC] ElvUI detected, interface skinned.|r")
    else
        print("|cffff0000[ORC] ElvUI skin failed, using default look: " .. tostring(err) .. "|r")
    end
end

-- Auto-reinit on level up + the post-combat retry for a reinit deferred in combat.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LEVEL_UP" then
        if OptimalRaidCompDB.autoLevelUp == false then return end
        if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then return end
        ReinitBots(BuildCompFromSlots())
    elseif event == "PLAYER_REGEN_ENABLED" then
        if reinitPending then
            reinitPending = false
            local comp = pendingReinitComp or BuildCompFromSlots()
            pendingReinitComp = nil
            After(3, function() ReinitBots(comp) end)
        end
    end
end)

local l = CreateFrame("Frame"); l:RegisterEvent("PLAYER_LOGIN")
l:SetScript("OnEvent", function()
    frame:SetScale(OptimalRaidCompDB.scale or 1.0)
    
    if OptimalRaidCompDB.currentComp and OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] then
        local data = OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp]
        OptimalRaidCompDB.raidSize = data.size or 25

        for j = 1, MAX_ROWS do
            if data.slots[j] then
                slots[j] = { class = data.slots[j].class, spec = data.slots[j].spec, opt1 = data.slots[j].opt1 or "none", opt2 = data.slots[j].opt2 or "none", isPlayer = data.slots[j].isPlayer }
            else
                slots[j] = { class = "Warrior", spec = "prot", opt1 = "none", opt2 = "none", isPlayer = false }
            end
        end
    end

    RefreshSizeDD(); RefreshCompList(); UpdateVisibleRows()
    ApplyElvUISkin()
end)

-- ==================== KEYBINDINGS ====================
-- Globals referenced by Bindings.xml (the only intentional globals; WoW's binding
-- system can only call functions by name). Labels for the Key Bindings UI.
BINDING_HEADER_OPTIMALRAIDCOMP = "Optimal Raid Comp"
BINDING_NAME_ORC_TOGGLE    = "Toggle ORC window"
BINDING_NAME_ORC_SUMMON    = "Summon bots"
BINDING_NAME_ORC_ATTACK    = "Attack (tank's target)"
BINDING_NAME_ORC_FOLLOW    = "Follow"
BINDING_NAME_ORC_STAY      = "Stay"
BINDING_NAME_ORC_RTSC_ON   = "RTSC on"
BINDING_NAME_ORC_RTSC_SAVE = "RTSC save waypoint 1"
BINDING_NAME_ORC_RTSC_GO   = "RTSC go waypoint 1"

function ORC_Toggle()    if frame:IsShown() then frame:Hide() else frame:Show() end end
function ORC_Summon()    SendBotOrder("summon") end
function ORC_Attack()    SendBotOrder("@tank attack") end
function ORC_Follow()    SendBotOrder("follow") end
function ORC_Stay()      SendBotOrder("stay") end
function ORC_RTSC_On()   SendBotOrder("rtsc") end
function ORC_RTSC_Save() SendBotOrder("rtsc save 1") end
function ORC_RTSC_Go()   SendBotOrder("rtsc go 1") end

SLASH_ORC1 = "/orc"
SlashCmdList["ORC"] = function(msg)
    msg = string.lower(msg or "")
    msg = string.gsub(msg, "^%s+", ""); msg = string.gsub(msg, "%s+$", "")
    if msg == "reinit" then ReinitBots(BuildCompFromSlots()); return end
    if msg == "loot" then SetGroupLoot(); return end
    if msg == "tradevalue" then PrintTradeValue(); return end
    if msg == "tradewhisper" or msg == "tradewhisper on" or msg == "tradewhisper off" then
        if msg == "tradewhisper on" then OptimalRaidCompDB.tradeWhisper = true
        elseif msg == "tradewhisper off" then OptimalRaidCompDB.tradeWhisper = false
        else OptimalRaidCompDB.tradeWhisper = not OptimalRaidCompDB.tradeWhisper end
        print("|cff00ff00[ORC] Trade payout whisper: "..(OptimalRaidCompDB.tradeWhisper and "ON" or "OFF").."|r")
        return
    end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end