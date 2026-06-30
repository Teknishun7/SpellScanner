--[[
    SpellScanner.lua
    WoW 3.3.5a (WotLK) addon
 
    Scans the player's spellbook to determine the maximum known rank of
    every spell, then scans all action bar slots (including stance/form
    bars, e.g. Shadowform, Druid shapeshifts, Warrior stances) and reports
    any spell whose bound rank is lower than the max rank currently known.
 
    Note: this server's client doesn't expose the newer tooltip API
    (SetSpellBookItem / GetSpellBookItemInfo), so this relies on
    GetSpellName / GetSpellInfo with the index+booktype calling
    convention, cross-validated against the tooltip's displayed name to
    avoid ever trusting a mismatched spell/rank.
 
    Slash command:
        /spellscanner   or   /ss   - run a full scan, opens a results window
]]
 
SpellScanner = {}
 
local ADDON_NAME = "SpellScanner"
local PREFIX = "|cff33ccffSpellScanner|r: "
 
-- ---------------------------------------------------------------------
-- Hidden scanning tooltip
-- ---------------------------------------------------------------------
 
local scanTip = CreateFrame("GameTooltip", "SpellScannerScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")
 
local function GetTooltipFirstLine()
    local fs = _G["SpellScannerScanTooltipTextLeft1"]
    return fs and fs:GetText() or nil
end
 
-- Returns name (from tooltip, always trustworthy), rankNum (only if we can
-- cross-validate it against the same name), and a diagnostic note.
-- Works for direct spells AND macros, since SetAction() resolves macros
-- to their underlying spell automatically when rendering the tooltip.
local function ReadActionSpellRank(slot)
    scanTip:ClearLines()
    local ok = pcall(scanTip.SetAction, scanTip, slot)
    if not ok then
        return nil, nil, "SetAction call failed"
    end
    local tooltipName = GetTooltipFirstLine()
    if not tooltipName then
        return nil, nil, "no tooltip"
    end
 
    local actionType, id = GetActionInfo(slot)
    if actionType ~= "spell" or not id then
        return tooltipName, nil, "non-spell action (" .. tostring(actionType) .. ")"
    end
 
    -- Try id as a spellbook index first (matches the spellbook scan method)
    local okA, nameA, rankA = pcall(GetSpellInfo, id, BOOKTYPE_SPELL)
    if okA and nameA == tooltipName and rankA then
        local rankNum = tonumber(rankA:match("^Rank (%d+)$"))
        if rankNum then
            return tooltipName, rankNum, "ok"
        end
    end
 
    -- Fall back to id as a true spellID
    local okB, nameB, rankB = pcall(GetSpellInfo, id)
    if okB and nameB == tooltipName and rankB then
        local rankNum = tonumber(rankB:match("^Rank (%d+)$"))
        if rankNum then
            return tooltipName, rankNum, "ok"
        end
    end
 
    return tooltipName, nil, "rank undetermined"
end
 
-- ---------------------------------------------------------------------
-- Results window (scrollable + selectable text, for easy copying)
-- ---------------------------------------------------------------------
 
local resultsFrame
 
local function GetResultsFrame()
    if resultsFrame then
        return resultsFrame
    end
 
    local f = CreateFrame("Frame", "SpellScannerResultsFrame", UIParent)
    f:SetSize(560, 420)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
 
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
 
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("TOP", f, "TOP", 0, -16)
    f.title:SetText("SpellScanner Results")
 
    local closeButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
 
    local scrollFrame = CreateFrame("ScrollFrame", "SpellScannerResultsScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 20)
 
    local editBox = CreateFrame("EditBox", "SpellScannerResultsEditBox", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(480)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetText("")
 
    scrollFrame:SetScrollChild(editBox)
    f.editBox = editBox
 
    resultsFrame = f
    return f
end
 
local function ShowResults(text)
    local f = GetResultsFrame()
    f.editBox:SetText(text)
    f.editBox:HighlightText(0, 0)
    f:Show()
end
 
-- ---------------------------------------------------------------------
-- Slot label helper
-- ---------------------------------------------------------------------
 
local function GetSlotLabel(slot)
    if slot >= 1 and slot <= 12 then
        return string.format("Main Bar slot %d", slot)
    elseif slot >= 13 and slot <= 24 then
        return string.format("Bottom Left Bar slot %d", slot - 12)
    elseif slot >= 25 and slot <= 36 then
        return string.format("Bottom Right Bar slot %d", slot - 24)
    elseif slot >= 37 and slot <= 48 then
        return string.format("Right Bar slot %d", slot - 36)
    elseif slot >= 49 and slot <= 60 then
        return string.format("Right Bar 2 slot %d", slot - 48)
    elseif slot >= 61 and slot <= 72 then
        return string.format("Stance/Bonus Bar slot %d", slot - 60)
    else
        return string.format("Page Bar slot %d", slot)
    end
end
 
-- ---------------------------------------------------------------------
-- Core scan
-- ---------------------------------------------------------------------
 
local function BuildMaxRankTable()
    local maxRanks = {}
    local numTabs = GetNumSpellTabs() or 0
 
    for tabIndex = 1, numTabs do
        local _, _, offset, numSpells = GetSpellTabInfo(tabIndex)
        offset = offset or 0
        numSpells = numSpells or 0
        for n = 1, numSpells do
            local i = offset + n
            local ok, name, rankText = pcall(GetSpellName, i, BOOKTYPE_SPELL)
            if ok and name then
                local rankNum = rankText and tonumber(rankText:match("^Rank (%d+)$"))
                if rankNum then
                    local existing = maxRanks[name]
                    if not existing or rankNum > existing.maxRank then
                        maxRanks[name] = { maxRank = rankNum }
                    end
                end
            end
        end
    end
 
    return maxRanks
end
 
local function RunScan()
    local maxRanks = BuildMaxRankTable()
 
    local downgraded = {}
    local maxed = {}
    local undetermined = {}
    local checked = 0
    local spellbookCount = 0
    for _ in pairs(maxRanks) do spellbookCount = spellbookCount + 1 end
 
    for slot = 1, 120 do
        if HasAction(slot) then
            pcall(function()
                local name, rankNum, note = ReadActionSpellRank(slot)
                if name then
                    local entry = maxRanks[name]
                    if entry then
                        if rankNum then
                            checked = checked + 1
                            if rankNum < entry.maxRank then
                                table.insert(downgraded, {
                                    slot = slot, name = name,
                                    currentRank = rankNum, maxRank = entry.maxRank,
                                })
                            else
                                table.insert(maxed, { slot = slot, name = name, rank = rankNum })
                            end
                        else
                            table.insert(undetermined, { slot = slot, name = name, note = note })
                        end
                    end
                end
            end)
        end
    end
 
    -- Build report text
    local out = {}
    table.insert(out, "SpellScanner Report")
    table.insert(out, string.format("Spellbook ranked spells found: %d", spellbookCount))
    table.insert(out, string.format("Action bar ranked spells checked: %d", checked))
    table.insert(out, "")
 
    if #downgraded == 0 then
        table.insert(out, "No downgraded spells found.")
    else
        table.insert(out, string.format("DOWNGRADED (%d):", #downgraded))
        for _, d in ipairs(downgraded) do
            table.insert(out, string.format(
                "  %s - %s is Rank %d, max known is Rank %d",
                GetSlotLabel(d.slot), d.name, d.currentRank, d.maxRank
            ))
        end
    end
 
    table.insert(out, "")
    table.insert(out, string.format("Max rank spells on bars (%d):", #maxed))
    for _, m in ipairs(maxed) do
        table.insert(out, string.format("  %s - %s (Rank %d)", GetSlotLabel(m.slot), m.name, m.rank))
    end
 
    if #undetermined > 0 then
        table.insert(out, "")
        table.insert(out, string.format("Could not determine rank (%d) - usually non-ranked utility spells:", #undetermined))
        for _, u in ipairs(undetermined) do
            table.insert(out, string.format("  %s - %s", GetSlotLabel(u.slot), u.name))
        end
    end
 
    print(PREFIX .. string.format(
        "Scan complete: %d checked, %d downgraded. Results window opened.",
        checked, #downgraded
    ))
 
    ShowResults(table.concat(out, "\n"))
end
 
-- ---------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------
 
SLASH_SPELLSCANNER1 = "/spellscanner"
SLASH_SPELLSCANNER2 = "/ss"
 
SlashCmdList["SPELLSCANNER"] = function()
    RunScan()
end
 
-- ---------------------------------------------------------------------
-- Load message
-- ---------------------------------------------------------------------
 
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON_NAME then
        print(PREFIX .. "Loaded. Type |cffffff00/ss|r to scan your action bars for outdated spell ranks.")
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

