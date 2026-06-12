-- Optimal Raid Comp Manager (v2.6)
-- Author: Runshouse (Original design by Xhausted)
-- Features: Priest Shadow Res toggle, Shaman Totem Dropdown Tooltips.

local PADDING, SLOT_HEIGHT = 10, 30
local CLASS_COL_WIDTH, SPEC_COL_WIDTH = 100, 90 

-- ==================== SAVED VARIABLES ====================
OptimalRaidCompDB = OptimalRaidCompDB or {
    comps = {},
    currentComp = nil,
    buttonPos = { x = -200, y = 0 },
    scale = 1.0,
    raidSize = 25
}

local activeSummonFrame = nil
local activeSortFrame = nil

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

-- Context-Aware Mutually Exclusive Options
local function GetOptionsForClassSpec(class, spec)
    local opt1List, opt2List = nil, nil
    if class == "Paladin" then
        opt1List = {"kings", "might", "wisdom"}
        if spec == "prot" then table.insert(opt1List, "sanctuary") end
        opt2List = {"devotion", "retribution", "concentration", "fire res", "frost res", "shadow res"}
    elseif class == "Shaman" then
        opt1List = {"melee", "caster", "healing", "fire res", "frost res", "nature res"}
    elseif class == "Warrior" then
        opt1List = {"battle", "commanding"}
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
        { class = "Warrior", spec = "prot", opt1 = "commanding", opt2 = "none", isPlayer = false },
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

local function PushSpecs(comp)
    if not comp or not comp.slots then return end
    print("|cff00ff00[ORC] Pushing spec commands...|r")
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

    local count = 0
    for _, m in ipairs(bots) do
        local short = UNIT_TO_SHORT[m.class]
        if short and specQueues[short] and #specQueues[short] > 0 then
            local data = table.remove(specQueues[short], 1)
            SendChatMessage("talents spec "..data.spec.." pve", "WHISPER", nil, m.name)
            
            if data.opt1 and data.opt1 ~= "none" then
                if short == "Shaman" then 
                    SendChatMessage("nc totems "..data.opt1, "WHISPER", nil, m.name)
                else 
                    local cmd = STRAT_MAP[data.opt1] or data.opt1
                    SendChatMessage("nc +"..cmd, "WHISPER", nil, m.name) 
                end
            end
            if data.opt2 and data.opt2 ~= "none" then
                local cmd = STRAT_MAP[data.opt2] or data.opt2
                SendChatMessage("nc +"..cmd, "WHISPER", nil, m.name)
            end
            
            count = count + 1
        end
    end
    print("|cff00ff00[ORC] Spec/Buff whispers sent to " .. count .. " bots.|r")
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
                    for _, tp in ipairs(toProcess) do 
                        SendChatMessage("talents spec "..tp.spec.." pve", "WHISPER", nil, tp.name)
                        if tp.opt1 and tp.opt1 ~= "none" then
                            if tp.class == "Shaman" then 
                                SendChatMessage("nc totems "..tp.opt1, "WHISPER", nil, tp.name)
                            else 
                                local cmd = STRAT_MAP[tp.opt1] or tp.opt1
                                SendChatMessage("nc +"..cmd, "WHISPER", nil, tp.name) 
                            end
                        end
                        if tp.opt2 and tp.opt2 ~= "none" then
                            local cmd = STRAT_MAP[tp.opt2] or tp.opt2
                            SendChatMessage("nc +"..cmd, "WHISPER", nil, tp.name)
                        end
                    end
                    print("|cffffff00[ORC] Specs pushed. Waiting 10s for Autogear...|r")
                    
                    local gearWaitStart, gearPushed = GetTime(), false
                    it:SetScript("OnUpdate", function(gearSelf)
                        local elapsed = GetTime() - gearWaitStart
                        if elapsed >= 10 and not gearPushed then
                            SendChatMessage("autogear", isRaid and "RAID" or "PARTY")
                            print("|cff00ff00[ORC] Autogear sent. Waiting 2s for World Buffs...|r")
                            gearPushed = true
                        elseif elapsed >= 12 and gearPushed then
                            gearSelf:SetScript("OnUpdate", nil)
                            SendChatMessage("nc +worldbuff", isRaid and "RAID" or "PARTY")
                            print("|cff00ff00[ORC] World Buffs sent! Setup Complete!|r")
                            if isRaid then activeSummonFrame = nil; SortRaidGroup(comp) else activeSummonFrame = nil end
                        end
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
    local wStart = GetTime()
    watchFrame:SetScript("OnUpdate", function(self)
        local members, _ = GetPartyMembers()
        if #members <= 1 or (GetTime() - wStart > 5) then self:Hide(); StartSummoning() end
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

-- ==================== GUI ====================
local frame = CreateFrame("Frame", "OptimalRaidCompFrame", UIParent)
frame:SetSize(700, 465)
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

local VISIBLE_ROWS, MAX_ROWS, ROW_HEIGHT = 10, 25, 30
local scrollContainer = CreateFrame("Frame", nil, frame); scrollContainer:SetPoint("TOPLEFT", 15, -45); scrollContainer:SetPoint("BOTTOMRIGHT", -35, 120) 
local fauxScroll = CreateFrame("ScrollFrame", "OptimalRaidCompFauxScroll", scrollContainer, "FauxScrollFrameTemplate")
fauxScroll:SetPoint("TOPLEFT", 0, 0); fauxScroll:SetPoint("BOTTOMRIGHT", -25, 0)

slots = {}
for i = 1, MAX_ROWS do slots[i] = { class = "Warrior", spec = "prot", opt1 = "none", opt2 = "none", isPlayer = false } end

local visibleRows = {}
function UpdateVisibleRows()
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

local saveBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); saveBtn:SetSize(60, 22); saveBtn:SetPoint("LEFT", compDD, "RIGHT", -10, 2); saveBtn:SetText("Save")
local renBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); renBtn:SetSize(65, 22); renBtn:SetPoint("LEFT", saveBtn, "RIGHT", 5, 0); renBtn:SetText("Rename")
local delBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"); delBtn:SetSize(60, 22); delBtn:SetPoint("LEFT", renBtn, "RIGHT", 5, 0); delBtn:SetText("Delete")

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
function RefreshCompList()
    UIDropDownMenu_Initialize(compDD, function()
        for name, data in pairs(OptimalRaidCompDB.comps) do
            local cSize = data.size or 25
            if name == "Default 5-Man" then cSize = 5 end
            
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
    local currSize = currData and (currData.size or (OptimalRaidCompDB.currentComp == "Default 5-Man" and 5 or 25))
    if currSize == OptimalRaidCompDB.raidSize then UIDropDownMenu_SetText(compDD, OptimalRaidCompDB.currentComp)
    else UIDropDownMenu_SetText(compDD, "Select Profile"); OptimalRaidCompDB.currentComp = nil end
end

function RefreshSizeDD()
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

-- POPUP DEFINITIONS
StaticPopupDialogs["ORC_SAVE_NEW"] = {
    text = "Name your new template:", button1 = "Save", button2 = "Cancel", hasEditBox = 1,
    OnShow = function(self) self.editBox:SetText("Comp " .. math.random(100, 999)); self.editBox:HighlightText() end,
    OnAccept = function(self)
        local name = self.editBox:GetText()
        if name ~= "" then
            OptimalRaidCompDB.comps[name] = { size = OptimalRaidCompDB.raidSize, slots = {} }
            for j=1, MAX_ROWS do
                OptimalRaidCompDB.comps[name].slots[j] = { class=slots[j].class, spec=slots[j].spec, opt1=slots[j].opt1, opt2=slots[j].opt2, isPlayer=slots[j].isPlayer }
            end
            OptimalRaidCompDB.currentComp = name; RefreshCompList(); UIDropDownMenu_SetText(ORC_MainCompDD, name)
        end
    end,
    EditBoxOnEnterPressed = function(self) self:GetParent().button1:Click() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1
}

StaticPopupDialogs["ORC_RENAME"] = { text = "Rename Template:", button1 = "Rename", button2 = "Cancel", hasEditBox = 1, OnAccept = function(self) local new = self.editBox:GetText(); if new ~= "" and OptimalRaidCompDB.currentComp then OptimalRaidCompDB.comps[new] = OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp]; OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] = nil; OptimalRaidCompDB.currentComp = new; RefreshCompList() end end, timeout = 0, whileDead = 1, hideOnEscape = 1 }

saveBtn:SetScript("OnClick", function() StaticPopup_Show("ORC_SAVE_NEW") end)
renBtn:SetScript("OnClick", function() if OptimalRaidCompDB.currentComp then StaticPopup_Show("ORC_RENAME") end end)
delBtn:SetScript("OnClick", function()
    if OptimalRaidCompDB.currentComp then OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] = nil; OptimalRaidCompDB.currentComp = nil; UIDropDownMenu_SetText(compDD, "Select"); RefreshCompList() end
end)

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

local l = CreateFrame("Frame"); l:RegisterEvent("PLAYER_LOGIN")
l:SetScript("OnEvent", function()
    frame:SetScale(OptimalRaidCompDB.scale or 1.0)
    
    if OptimalRaidCompDB.currentComp and OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp] then
        local data = OptimalRaidCompDB.comps[OptimalRaidCompDB.currentComp]
        OptimalRaidCompDB.raidSize = data.size or 25
        if OptimalRaidCompDB.currentComp == "Default 5-Man" then OptimalRaidCompDB.raidSize = 5 end
        
        for j = 1, MAX_ROWS do
            if data.slots[j] then
                slots[j] = { class = data.slots[j].class, spec = data.slots[j].spec, opt1 = data.slots[j].opt1 or "none", opt2 = data.slots[j].opt2 or "none", isPlayer = data.slots[j].isPlayer }
            else
                slots[j] = { class = "Warrior", spec = "prot", opt1 = "none", opt2 = "none", isPlayer = false }
            end
        end
    end

    RefreshSizeDD(); RefreshCompList(); UpdateVisibleRows()
end)

SLASH_ORC1 = "/orc"
SlashCmdList["ORC"] = function() if frame:IsShown() then frame:Hide() else frame:Show() end end