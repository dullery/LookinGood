-- Lookin' Good
-- Tracks online guild members and prompts you to greet them when you're near.
--
-- Where positions come from:
--   * Guildmates who also run Lookin' Good broadcast their world position over the
--     hidden GUILD addon channel, so we know exactly how far away they are.
--   * Guildmates without the addon are detected when they show up as a unit token
--     (party/raid, target, focus, mouseover, friendly nameplates) and pass a range check.
--
-- Why there is a button: on the Retail client (which WoW Forever uses), /say outside
-- instances can only be sent from a hardware event (a click or key press). So the
-- addon queues the greeting and you send it with one click or your keybind.

local ADDON_NAME = ...
local PREFIX = "LookinGood"

local TICK_SECONDS = 1
local BROADCAST_HEARTBEAT = 20   -- seconds between position updates while standing still
local BROADCAST_MIN_INTERVAL = 3 -- never broadcast more often than this
local BROADCAST_MIN_MOVE = 5     -- yards moved before sending an early update
local STALE_AFTER = 45           -- forget a broadcast position after this many seconds
local PENDING_TTL = 90           -- drop an unanswered greeting prompt after this many seconds
local ROSTER_REFRESH = 30        -- seconds between guild roster requests
local RANGE_ITEM_15 = 1251       -- Linen Bandage: usable on friendly units within 15 yards
local INTERACT_TRADE = 2         -- CheckInteractDistance trade range, about 11 yards
local INTERACT_FOLLOW = 4        -- CheckInteractDistance follow range, about 28 yards
local DB_VERSION = 2

local DEFAULTS = {
	enabled = true,
	share = true,
	range = 15,
	cooldown = 30,
	message = "Hey {name}! Lookin' good!",
}

BINDING_HEADER_LOOKINGOOD = "Lookin' Good"
BINDING_NAME_LOOKINGOOD_GREET = "Greet nearby guildmate"

local db
local myName
local online = {}      -- [fullName] = zone, from the guild roster
local positions = {}   -- [fullName] = { instance, x, y, time }, from addon broadcasts
local pending = {}     -- ordered list of { name, time } waiting to be greeted
local lastBroadcast = { time = 0 }
local lastRosterRequest = 0
local button
local UpdateButton

local UNITS = { "target", "focus", "mouseover" }
for i = 1, 4 do UNITS[#UNITS + 1] = "party" .. i end
for i = 1, 40 do UNITS[#UNITS + 1] = "raid" .. i end
for i = 1, 40 do UNITS[#UNITS + 1] = "nameplate" .. i end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(msg)
	print("|cff33ff99Lookin' Good|r: " .. msg)
end

-- Midnight-era clients hide some values from addons ("secret values"),
-- mostly during combat. Never compare or concatenate one.
local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local function FullName(name)
	if not name then return nil end
	if not name:find("-", 1, true) then
		local realm = GetNormalizedRealmName()
		if realm then name = name .. "-" .. realm end
	end
	return name
end

local function ShortName(name)
	return (strsplit("-", name))
end

local function MyRealm()
	return GetNormalizedRealmName() or (GetRealmName():gsub("[%s%-]", ""))
end

-- True if a "Name" or "Name-Realm" string refers to the player.
-- Compared piecewise so a missing or differently formatted realm can't slip through.
local function IsMe(name)
	if not name or IsSecret(name) then return true end -- can't tell, so treat it as us
	local short, realm = name:match("^([^-]+)-?(.*)$")
	if short ~= UnitName("player") then return false end
	return realm == "" or realm:gsub("[%s%-]", "") == MyRealm()
end

local function UnitFullNameOf(unit)
	local name, realm = UnitName(unit)
	if not name or IsSecret(name) or IsSecret(realm) then return nil end
	if realm and realm ~= "" then return name .. "-" .. realm end
	return FullName(name)
end

local function Distance(x1, y1, x2, y2)
	local dx, dy = x1 - x2, y1 - y2
	return math.sqrt(dx * dx + dy * dy)
end

-- World position in yards. UnitPosition is unavailable inside instances.
local function MyPosition()
	if IsInInstance() then return nil end
	local y, x, _, instance = UnitPosition("player")
	if not y or IsSecret(y) then return nil end
	return x, y, instance
end

---------------------------------------------------------------------------
-- Guild roster
---------------------------------------------------------------------------

local function RefreshRoster()
	wipe(online)
	if not IsInGuild() then return end
	for i = 1, GetNumGuildMembers() do
		local name, _, _, _, _, zone, _, _, isOnline = GetGuildRosterInfo(i)
		if name and isOnline then
			online[FullName(name)] = zone or "Unknown"
		end
	end
end

local function RequestRoster(now)
	if IsInGuild() and now - lastRosterRequest >= ROSTER_REFRESH then
		lastRosterRequest = now
		C_GuildInfo.GuildRoster()
	end
end

---------------------------------------------------------------------------
-- Greeting queue
---------------------------------------------------------------------------

local function FindPending(name)
	for i, entry in ipairs(pending) do
		if entry.name == name then return i end
	end
end

local function PrunePending()
	local now, removed = GetTime(), false
	for i = #pending, 1, -1 do
		if now - pending[i].time > PENDING_TTL then
			table.remove(pending, i)
			removed = true
		end
	end
	if removed then UpdateButton() end
end

local function OnCooldown(name)
	local last = db.lastGreeted[name]
	return last ~= nil and (time() - last) < db.cooldown * 60
end

local function Consider(name)
	if IsMe(name) or OnCooldown(name) then return end
	local i = FindPending(name)
	if i then
		pending[i].time = GetTime() -- still nearby, keep the prompt alive
		return
	end
	pending[#pending + 1] = { name = name, time = GetTime() }
	Print(("%s is nearby. Click the button or press your keybind to say hi."):format(ShortName(name)))
	UpdateButton()
end

function LookinGood_GreetNext()
	PrunePending()
	local entry = table.remove(pending, 1)
	if not entry then
		Print("No guildmates waiting for a greeting.")
		UpdateButton()
		return
	end
	local text = (db.message:gsub("{name}", ShortName(entry.name)))
	SendChat(text, "SAY")
	db.lastGreeted[entry.name] = time()
	UpdateButton()
end

local function SkipNext()
	local entry = table.remove(pending, 1)
	if entry then db.lastGreeted[entry.name] = time() end
	UpdateButton()
end

---------------------------------------------------------------------------
-- Position sharing (addon channel)
---------------------------------------------------------------------------

local function SendAddon(text)
	pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "GUILD")
end

local function Broadcast(now)
	if not db.share or not IsInGuild() or InCombatLockdown() then return end
	if now - lastBroadcast.time < BROADCAST_MIN_INTERVAL then return end
	local x, y, instance = MyPosition()
	if not x then return end

	local moved = math.huge
	if lastBroadcast.x and lastBroadcast.instance == instance then
		moved = Distance(x, y, lastBroadcast.x, lastBroadcast.y)
	end
	if moved < BROADCAST_MIN_MOVE and now - lastBroadcast.time < BROADCAST_HEARTBEAT then return end

	SendAddon(("P:%d:%.1f:%.1f"):format(instance, x, y))
	lastBroadcast = { time = now, x = x, y = y, instance = instance }
end

local function OnAddonMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX or channel ~= "GUILD" or not myName then return end
	if IsSecret(text) or IsSecret(sender) then return end
	local name = FullName(sender)
	if IsMe(name) then return end -- guild addon messages echo back to the sender

	if text == "H" then
		positions[name] = nil
		return
	end
	local instance, x, y = text:match("^P:(%-?%d+):(%-?[%d%.]+):(%-?[%d%.]+)$")
	if instance then
		positions[name] = {
			instance = tonumber(instance),
			x = tonumber(x),
			y = tonumber(y),
			time = GetTime(),
		}
	end
end

---------------------------------------------------------------------------
-- Proximity detection
---------------------------------------------------------------------------

-- Range check for guildmates who don't broadcast a position.
local function FallbackInRange(unit)
	if db.range >= 28 then
		local ok, inRange = pcall(CheckInteractDistance, unit, INTERACT_FOLLOW)
		return ok and not IsSecret(inRange) and inRange
	end
	if db.range >= 15 and C_Item and C_Item.IsItemInRange then
		local ok, inRange = pcall(C_Item.IsItemInRange, RANGE_ITEM_15, unit)
		if ok and inRange ~= nil and not IsSecret(inRange) then return inRange end
	end
	local ok, inRange = pcall(CheckInteractDistance, unit, INTERACT_TRADE)
	return ok and not IsSecret(inRange) and inRange
end

local function IsPlayerUnit(unit)
	local isSelf = UnitIsUnit(unit, "player")
	if IsSecret(isSelf) or isSelf then return true end
	local guid, myGUID = UnitGUID(unit), UnitGUID("player")
	return IsSecret(guid) or guid == myGUID
end

local function CheckUnit(unit, mx, my, minstance)
	if not UnitExists(unit) or not UnitIsPlayer(unit) or IsPlayerUnit(unit) then return end
	local inGuild = UnitIsInMyGuild(unit)
	if IsSecret(inGuild) or not inGuild or not UnitIsConnected(unit) then return end
	local name = UnitFullNameOf(unit)
	if not name or IsMe(name) then return end

	local near
	-- Group members: exact distance, honoring the configured range.
	if mx and (UnitInParty(unit) or UnitInRaid(unit)) then
		local uy, ux, _, uinstance = UnitPosition(unit)
		if uy and not IsSecret(uy) and uinstance == minstance then
			near = Distance(mx, my, ux, uy) <= db.range
		end
	end
	if near == nil then near = FallbackInRange(unit) end
	if near then Consider(name) end
end

local function Tick()
	if not db then return end
	local now = GetTime()
	RequestRoster(now)
	Broadcast(now)

	local mx, my, minstance = MyPosition()
	for name, p in pairs(positions) do
		if now - p.time > STALE_AFTER then positions[name] = nil end
	end

	PrunePending()
	if not db.enabled or not IsInGuild() or InCombatLockdown() then return end

	if mx then
		for name, p in pairs(positions) do
			if p.instance == minstance and Distance(mx, my, p.x, p.y) <= db.range then
				Consider(name)
			end
		end
	end
	for _, unit in ipairs(UNITS) do
		CheckUnit(unit, mx, my, minstance)
	end
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function CreateButton()
	button = CreateFrame("Button", "LookinGoodButton", UIParent, "UIPanelButtonTemplate")
	button:SetSize(220, 28)
	button:SetFrameStrata("HIGH")
	local p = db.buttonPoint
	if p then
		button:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		button:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
	end
	button:SetMovable(true)
	button:SetClampedToScreen(true)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnDragStart", function(self)
		if IsShiftKeyDown() then self:StartMoving() end
	end)
	button:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		db.buttonPoint = { point, relPoint, x, y }
	end)
	button:SetScript("OnClick", function(_, mouse)
		if IsShiftKeyDown() then return end
		if mouse == "RightButton" then SkipNext() else LookinGood_GreetNext() end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Lookin' Good")
		GameTooltip:AddLine("Left-click: /say the greeting", 1, 1, 1)
		GameTooltip:AddLine("Right-click: skip", 1, 1, 1)
		GameTooltip:AddLine("Shift-drag: move", 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	button:Hide()
end

UpdateButton = function()
	if not button then return end
	if #pending == 0 then
		button:Hide()
		return
	end
	local label = "Say hi to " .. ShortName(pending[1].name)
	if #pending > 1 then label = label .. (" (+%d)"):format(#pending - 1) end
	button:SetText(label)
	button:Show()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function ListMembers()
	local names = {}
	for name in pairs(online) do
		if not IsMe(name) then names[#names + 1] = name end
	end
	if #names == 0 then
		Print("No other guild members online.")
		return
	end
	table.sort(names)
	local mx, my, minstance = MyPosition()
	Print(("%d guild members online:"):format(#names))
	for _, name in ipairs(names) do
		local line = ShortName(name) .. " - " .. online[name]
		local p = positions[name]
		if p and mx and p.instance == minstance then
			line = line .. (" |cffffd100(%d yds)|r"):format(Distance(mx, my, p.x, p.y))
		end
		print("  " .. line)
	end
end

local function ShowHelp()
	Print("commands (/lg or /lookingood):")
	print("  /lg list - online guild members, zone, and distance if known")
	print("  /lg greet - say hi to the next nearby guildmate")
	print(("  /lg on | off - greeting prompts (now %s)"):format(db.enabled and "on" or "off"))
	print(("  /lg share on | off - share your position with the guild (now %s)"):format(db.share and "on" or "off"))
	print(("  /lg range <yards> - greeting distance (now %d)"):format(db.range))
	print(("  /lg cooldown <minutes> - wait before greeting the same person again (now %d)"):format(db.cooldown))
	print(("  /lg message <text> - use {name} for their name (now \"%s\")"):format(db.message))
	print("  /lg reset - clear greeting cooldowns")
end

local function OnSlash(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()

	if cmd == "list" then
		ListMembers()
	elseif cmd == "greet" then
		LookinGood_GreetNext()
	elseif cmd == "on" or cmd == "off" then
		db.enabled = (cmd == "on")
		if not db.enabled then
			wipe(pending)
			UpdateButton()
		end
		Print("greeting prompts " .. cmd .. ".")
	elseif cmd == "share" and (rest == "on" or rest == "off") then
		db.share = (rest == "on")
		if not db.share then SendAddon("H") end
		Print("position sharing " .. rest .. ".")
	elseif cmd == "range" and tonumber(rest) then
		db.range = math.max(1, tonumber(rest))
		Print(("range set to %d yards."):format(db.range))
	elseif cmd == "cooldown" and tonumber(rest) then
		db.cooldown = math.max(0, tonumber(rest))
		Print(("cooldown set to %d minutes."):format(db.cooldown))
	elseif cmd == "message" and rest ~= "" then
		db.message = rest
		Print(("message set to \"%s\"."):format(rest))
	elseif cmd == "reset" then
		wipe(db.lastGreeted)
		Print("greeting cooldowns cleared.")
	else
		ShowHelp()
	end
end

SLASH_LOOKINGOOD1 = "/lookingood"
SLASH_LOOKINGOOD2 = "/lg"
SlashCmdList.LOOKINGOOD = OnSlash

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GUILD_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")

events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= ADDON_NAME then return end
		LookinGoodDB = LookinGoodDB or {}
		db = LookinGoodDB
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then db[key] = value end
		end
		db.lastGreeted = db.lastGreeted or {}
		if (db.version or 1) < 2 and db.range == 25 then db.range = 15 end -- old default
		db.version = DB_VERSION
		CreateButton()
	elseif event == "PLAYER_LOGIN" then
		myName = FullName(UnitName("player"))
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		if C_Item and C_Item.RequestLoadItemDataByID then
			C_Item.RequestLoadItemDataByID(RANGE_ITEM_15) -- range checks need it cached
		end
		RequestRoster(GetTime())
		C_Timer.NewTicker(TICK_SECONDS, Tick)
	elseif event == "GUILD_ROSTER_UPDATE" then
		RefreshRoster()
	elseif event == "CHAT_MSG_ADDON" then
		OnAddonMessage(...)
	end
end)
