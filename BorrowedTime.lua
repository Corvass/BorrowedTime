--[[
**********************************************************************
BorrowedTime - cooldown, buff and debuff bar display
**********************************************************************
This file is part of Borrowed Time, a World of Warcraft Addon

Borrowed Time is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Borrowed Time is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with Borrowed Time. If not, see <http://www.gnu.org/licenses/>.

**********************************************************************
]]

BorrowedTime = LibStub("AceAddon-3.0"):NewAddon("Borrowed Time", "AceEvent-3.0", "LibBars-1.0", 
					"AceTimer-3.0", "AceConsole-3.0")
local mod = BorrowedTime

local L = LibStub("AceLocale-3.0"):GetLocale("BorrowedTime", false)

-- Silently fail embedding if it doesn't exist
local LibStub = LibStub
local LDBIcon = LibStub("LibDBIcon-1.0", true)
local LDB = LibStub("LibDataBroker-1.1", true)
local AceGUIWidgetLSMlists = AceGUIWidgetLSMlists

local Logger = LibStub("LibLogger-1.0", true)

local C = LibStub("AceConfigDialog-3.0")
local media = LibStub("LibSharedMedia-3.0")

local UnitExists = UnitExists
local UnitAura = UnitAura
local GetSpellCooldown = GetSpellCooldown
local GetSpellCharges = GetSpellCharges
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local PlaySoundFile = PlaySoundFile
local fmt = string.format
local max = max
local cos = math.cos
local min = min
local pairs = pairs
local ipairs = ipairs
local select = select
local sort = sort
local tostring = tostring
local type = type
local unpack = unpack
local TWOPI = math.pi * 2
local ceil = math.ceil

local gcd = 1.5
local playerInCombat = InCombatLockdown()
local idleAlphaLevel
local addonEnabled = false
local db, isInGroup
local bars, hiddenBars = nil, nil
local cooldownbars = {}
if Logger then
	Logger:Embed(mod)
else
	-- Enable info messages
	mod.info = function(self, ...)
		mod:Print(fmt(...))
	end
	mod.error = mod.info
	mod.warn = mod.info
	-- But disable debugging
	mod.debug = function(self, ...)
	end
	mod.trace = mod.debug
	mod.spam = mod.debug
end

local options

-- bar types
mod.COOLDOWN = 1
mod.DEBUFF	= 2
mod.BUFF = 3

local defaults = {
	profile = {
		flashMode = 2,
		hideInactiveDebuff = true,
		flashTimes = 2,
		readyFlash = true,
		readyFlashDuration = 0.5,
		sound = "None",
		soundOccasion = 1, -- Never
		font = "Friz Quadrata TT",
		fontsize = 14,
		hideAnchor = true,
		iconScale = 1.0,
		length = 250,
		secondsOnly = false, 
		orientation = 1,
		scale = 1.0,
		showIcon = true,
		showLabel = true,
		showTimer = true,
		alphaOOC = 1.0,
		alphaReady = 1.0,
		alphaGCD = 1.0,
		alphaActive = 0.5,
		fadeAlpha = true,
		spacing = 1,
		texture   = "Minimalist",
		bgtexture = "Minimalist",
		timerOnIcon = false, 
		thickness = 25,
		showSpark = true,
		minimapIcon = {}
	}
}

function mod:OnInitialize()
	-- Register some sound effects since they normally aren't available
	media:Register("sound", "Drop", [[Sound\Interface\DropOnGround.wav]])
	media:Register("sound", "Error", [[Sound\Interface\Error.wav]])
	media:Register("sound", "Magic Click", [[Sound\Interface\MagicClick.wav]])
	media:Register("sound", "Ping", [[Sound\Interface\MapPing.wav]])
	media:Register("sound", "Socket Clunk", [[Sound\Interface\JewelcraftingFinalize.wav]])
	media:Register("sound", "Whisper Ping", [[Sound\Interface\iTellMessage.wav]])
	media:Register("sound", "Whisper", [[Sound\Interface\igTextPopupPing02.wav]])
	self.db = LibStub("AceDB-3.0"):New("BorrowedTimeDB", defaults, "Default")
	self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
	self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
	self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")
	BorrowedTimeDB.point = nil
	BorrowedTimeDB.presets = nil
	db = self.db.profile
	idleAlphaLevel = playerInCombat and db.alphaReady or db.alphaOOC
	mod._readyFlash2 = db.readyFlashDuration/2   
	mod:UpdateLocalVariables()

	-- initial status
	mod:SetDefaultColors()
	if LDB then
		self.ldb =
			LDB:NewDataObject("Borrowed Time",
			{
				type = "launcher", 
				label = L["Borrowed Time"],
				icon = "Interface\\ICONS\\SPELL_HOLY_BORROWEDTIME",
				tooltiptext = L["|cffffff00Left click|r to open the configuration screen.\n|cffffff00Right click|r to toggle the Borrowed Time window lock."], 
				OnClick = function(clickedframe, button)
				if button == "LeftButton" then
					mod:ToggleConfigDialog()
				elseif button == "RightButton" then
					mod:ToggleLocked()
				end
			end,
			})
		if LDBIcon then
			LDBIcon:Register("BorrowedTime", self.ldb, db.minimapIcon)
		end
	end

	mod:SetupOptions()
end

function mod:OnEnable()
	if not bars then
		bars = mod:NewBarGroup(L["Borrowed Time"], nil, db.length, db.thickness)
		bars:SetColorAt(1.00, 1, 1, 0, 1)
		bars:SetColorAt(0.00, 0.5, 0.5, 0, 1)
		bars.RegisterCallback(self, "AnchorMoved")
		bars.ReverseGrowth = mod.__ReverseGrowth
		mod.cooldownbars = cooldownbars
		mod.bars = bars
		mod:UpdateLocalVariables()

		hiddenBars = mod:NewBarGroup("Hidden Bars", nil, 200, 20)
		hiddenBars:Hide()
	end

	mod:ApplyProfile()
	if self.SetLogLevel then
		mod:SetLogLevel(self.logLevels.TRACE)
	end
	mod:RegisterEvent("PLAYER_REGEN_ENABLED")
	mod:RegisterEvent("PLAYER_REGEN_DISABLED")
	mod:RegisterEvent("PLAYER_UNGHOST", "PLAYER_REGEN_ENABLED")
	mod:RegisterEvent("PLAYER_DEAD", "PLAYER_REGEN_ENABLED")
	mod:RegisterEvent("PLAYER_ALIVE", "PLAYER_REGEN_ENABLED")
	mod:RegisterEvent("PLAYER_TALENT_UPDATE", "PLAYER_REGEN_ENABLED")
	mod:RegisterEvent("LEARNED_SPELL_IN_TAB", "PLAYER_TALENT_UPDATE")
	mod:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_TALENT_UPDATE")
	mod:RegisterEvent("UNIT_AURA", "UpdateBuffStatus")
	mod:RegisterEvent("PLAYER_TARGET_CHANGED", "UpdateBuffStatus")
	mod:RegisterEvent("SPELL_UPDATE_COOLDOWN", "UpdateCooldownStatus")

end

-- We mess around with bars so restore them to a prestine state
-- Yes, this is evil and all but... so much fun... muahahaha
function mod:ReleaseBar(bar)
	bar.barId = nil
	bar.type   = nil
	bar.notReady = nil
	bar.iconPath = nil
	bar.overlayTexture:SetAlpha(0)
	bar.overlayTexture:Hide()
	bar.gcdnotify = false
	bar:SetScript("OnEnter", nil)
	bar:SetScript("OnLeave", nil)
	bar:SetValue(0)
	bar:SetScale(1)
	bar.spark:SetAlpha(1)
	bar.ownerGroup:RemoveBar(bar.name)
	bar.label:SetTextColor(1, 1, 1, 1)
	bar.timerLabel:SetTextColor(1, 1, 1, 1)
end

function mod:OnDisable()
	mod:UnregisterAllEvents()
end

do
	local now, updated, data, bar, playAlert, tmp, newValue
	local numActiveDots, numActiveCooldowns, scriptActive, resort

	local readyFlash = {}

	local spellInfo = {}
	local spellAlias = {}

	function mod:CreateBars()
		for id, bars in pairs(cooldownbars) do
			for jd, bar in pairs(bars) do
				if bar then
					mod:ReleaseBar(bar)
					cooldownbars[id][jd] = nil
				end
			end
			cooldownbars[id] = nil
		end

		spellInfo = {}
		spellInfo[mod.COOLDOWN] = {}
		spellInfo[mod.DEBUFF] = {}
		spellInfo[mod.BUFF] = {}

		spellAlias = {}
	   
		if not db.bars then
			return
		end
		for id, data in ipairs(db.bars) do
			local title, _, icon = GetSpellInfo(data.spell)
			data.title = data.spell

			if not data.hide and title ~= nil and title ~= '' then
				local charges = 1
				if data.type == mod.COOLDOWN then
					_, charges = GetSpellCharges(data.spell)
					charges = charges or 1
				end

				cooldownbars[id] = {}

				for jd = 1, charges do
					local bar = bars:NewCounterBar("BorrowedTime:"..id..":"..jd, "", db.showRemaining and 0 or 10, 10)
					bar.barId  = id * 10 + jd
					bar.sortValue = id * 10 + jd

					data.title = title
					data.icon = icon

					if not bar.overlayTexture then
						bar.overlayTexture = bar:CreateTexture(nil, "OVERLAY")
						bar.overlayTexture:SetTexture("Interface/Buttons/UI-Listbox-Highlight2")
						bar.overlayTexture:SetBlendMode("ADD")
						bar.overlayTexture:SetVertexColor(1, 1, 1, 0.6)
						bar.overlayTexture:SetAllPoints()
					else
						bar.overlayTexture:Show()
					end
					bar.overlayTexture:SetAlpha(0)
					bar:SetFrameLevel(100 + id * 10 + jd) -- this is here to ensure a "consistent" order of the icons in case they are sorted somehow

					spellInfo[data.type][data.spell] = {}
					spellAlias[title] = data.spell

					cooldownbars[id][jd] = bar
					mod:SetBarLabel(id, title)
					mod:SetBarColor(bar, data.color or {1, 1, 1, 1})
					bar:SetIcon(data.icon)

					if not db.showIcon then
						bar:HideIcon()
					end
					if not db.showLabel then
						bar:HideLabel()
					end
					if not db.showTimer then
						bar:HideTimerLabel()
					end
				end
			end
		end

		mod:SortAllBars()
		mod:UpdateBars()
		mod:SetupBarOptions(true)
	end

	function mod:FlipRemainingTimes()
		if db.flashTimes and db.flashMode == 2 then
			mod:RefreshBarColors()
		end
		for _, bars in pairs(cooldownbars) do
			for _, bar in pairs(bars) do
				if bar then
					bar:SetValue(bar.maxValue - bar.value)
				end
			end
		end
	end

	local function UpdateBuffDurations(spellInfo)
		for id, data in pairs(spellInfo) do
			if data.expirationTime ~= nil then
				if not data.ready then 
					data.remaining = data.expirationTime - now
					data.value = data.duration - data.remaining
					if data.remaining > 0 then
						numActiveDots = numActiveDots + 1
						if data.remaining < gcd and not data.notified then
							if db.soundOccasion == 2 then
								playAlert = true
							end
							data.notified = db.soundOccasion
						end
					end
				else
					if data.notified == 3 then
						playAlert = true
					end
					data.notified = nil
				end
			else
				-- just set defaults
				data.remaining = 0
				data.duration = 0
				data.expirationTime = 0
				data.stack = 0
			end
		end
	end

	local function UpdateCooldownDurations(spellInfo, t)
		for id, data in pairs(spellInfo) do
			data.remaining = max((data.start or 0) + (data.duration or 0) - now, 0)
			data.value = (data.duration or 10) - (data.remaining or 0)
			if data.remaining > 0 then
				numActiveCooldowns = numActiveCooldowns + 1
			end
			if data.ready or data.remaining <= 0 then
				data.alpha = idleAlphaLevel
				if data.flashing then
					data.flashTime = nil
					data.flashPeriod = nil
					data.flashing = nil
				end
				if data.notified == 3 then
					playAlert = true
				end
				data.notified = nil
			elseif data.remaining < gcd then
				if not data.notified then
					if db.soundOccasion == 2 then
						playAlert = true
					end
					data.notified = db.soundOccasion
				end
				if mod.flashTimer then
					if not data.flashing then
						data.alpha = 1.0
						data.flashTime = 0
						data.flashPeriod = data.remaining/mod.flashTimer
						data.flashing = true
					else
						if t then
							data.flashTime = data.flashTime + t
						end
						if data.flashTime > TWOPI then
							data.flashTime = data.flashTime - TWOPI
						end
						data.alpha = (cos(data.flashTime / data.flashPeriod) + 1) / 2
					end
				else
					if db.fadeAlphaGCD then
						tmp = data.remaining/gcd
						data.alpha = db.alphaGCD*tmp + idleAlphaLevel*(1-tmp)
					else
						data.alpha = db.alphaGCD
					end
				end
			elseif db.fadeAlpha then
				tmp = (data.remaining-gcd)/(10-gcd)
				data.alpha = db.alphaActive*tmp + db.alphaGCD*(1-tmp)
			else
				data.alpha = db.alphaActive
			end
		end
	end

	local function DoReadyFlash()
		for id, data in pairs(readyFlash) do
			if data and data.bars then
				local duration = now - data.start
				local charges = spellInfo[mod.COOLDOWN][data.spell].charges
				local bars = data.bars

				for jd, bar in pairs(bars) do
					if jd ~= charges or duration > db.readyFlashDuration then
						if duration > db.readyFlashDuration then
							readyFlash[id] = nil
						end
						bar.overlayTexture:SetAlpha(0)
					elseif duration >= mod._readyFlash2 then
						bar.overlayTexture:SetAlpha((db.readyFlashDuration - duration)/mod._readyFlash2)
					else
						bar.overlayTexture:SetAlpha(duration/mod._readyFlash2)
					end
				end
			end
		end
	end

	function mod:AddReadyFlash(bars, spell)
		for id, data in pairs(readyFlash) do
			if data and data.bars == bars then
				data.start = now
				return
			end
		end
		if not inserted then
			readyFlash[#readyFlash+1] = { start = now, bars = bars, spell = spell }
		end
	end

	local function UpdateBarDisplay()
		-- Check each bar for update
		for id, barData in ipairs(db.bars) do
			if cooldownbars[id] then
				for jd, bar in pairs(cooldownbars[id]) do
					if bar then
						data = spellInfo[barData.type][barData.spell]
						if barData.type ~= mod.COOLDOWN then
							mod:SetBarLabel(id, barData.title, data.stack)
						end
						if data.charges and data.charges ~= jd then
							if data.charges > jd then
								if db.showRemaining then
									bar:SetValue(0)
								else
									bar:SetValue(bar.maxValue)
								end
								bar.timerLabel:SetText("")
								bar.notReady = nil
							else
								if db.showRemaining then
									bar:SetValue(bar.maxValue)
								else
									bar:SetValue(0)
								end
								bar.timerLabel:SetText("")
								bar.notReady = true
							end
						else
							if data.flashing or barData.type == mod.COOLDOWN then
								bar:SetAlpha(data.alpha)
							elseif barData.type ~= mod.COOLDOWN then
								bar:SetAlpha(db.alphaReady)
							end
							if data.ready or data.remaining <= 0 then
								if barData.type ~= mod.COOLDOWN then
									-- Hide inactive buff and debuff bars
									if db.hideInactiveDebuff and bar.ownerGroup ~= hiddenBars then
										resort = true
										bars:MoveBarToGroup(bar, hiddenBars)
									else
										if db.showRemaining then
											bar:SetValue(bar.maxValue)
										else
											bar:SetValue(0)
										end
										bar:SetAlpha(db.alphaActive)
									end
								end

								if bar.notReady then
									if db.showRemaining then
										bar:SetValue(0)
									else
										bar:SetValue(bar.maxValue)
									end
									bar.timerLabel:SetText("")
									bar.notReady = nil
									if bar.gcdnotify then
										if db.readyFlash and barData.type == mod.COOLDOWN then
											mod:AddReadyFlash(cooldownbars[id], barData.spell)
										end
									end
									bar.gcdnotify = nil
								end
							else
								if barData.type ~= mod.COOLDOWN then
									-- Show newly active buff and debuff bars
									if db.hideInactiveDebuff and bar.ownerGroup ~= bars then
										hiddenBars:MoveBarToGroup(bar, bars)
										resort = true
									end
								end
								newValue = db.showRemaining and data.remaining or data.value
								if bar.value ~= newValue then
									if data.remaining < gcd then
										bar.gcdnotify = true
									end
									bar:SetValue(newValue, data.duration)
									if db.showTimer then
										if data.remaining == 0 then
											bar.timerLabel:SetText("")
										elseif data.remaining > gcd or db.secondsOnly then
											bar.timerLabel:SetText(fmt("%.0f", data.remaining))
										else
											bar.timerLabel:SetText(fmt("%.1f", data.remaining))
										end
									end
								end
								bar.notReady = true
							end
						end
					end
				end
			end
		end
	end

	function mod.UpdateBars(self, t)
		resort, playAlert = nil, nil
		numActiveDots, numActiveCooldowns = 0, 0
		now = GetTime()

		-- Update the value and remaining time for all cooldowns
		UpdateCooldownDurations(spellInfo[mod.COOLDOWN], t)
		-- this updates the remaining and current value of the dots/buffs
		UpdateBuffDurations(spellInfo[mod.DEBUFF])
		UpdateBuffDurations(spellInfo[mod.BUFF])

		-- Do the "cooldown is ready" flashing
		if db.readyFlash and #readyFlash > 0 then
			DoReadyFlash()
		end

		UpdateBarDisplay()

		if resort then
			mod:SetOrientation()
			mod:SetSize()
			hiddenBars:SortBars()
		end

		if playAlert and mod.soundFile then
			PlaySoundFile(mod.soundFile)
		end

		-- Check whether or not to cancel the OnUpdate method
		if #readyFlash > 0											-- animations
			or numActiveDots > 0		-- dot display active
			or numActiveCooldowns > 0	-- cooldown display active
			then
			-- something is going on, and timer isn't active so enable it
			if not scriptActive then
				bars:SetScript("OnUpdate", mod.UpdateBars)
				scriptActive = true
			end
		elseif scriptActive then
			-- We're active, but have nothing to do - disable OnUpdate
			bars:SetScript("OnUpdate", nil)
			scriptActive = nil
		end
	end

	function mod:UpdateBuffStatus(event, unit)
		local filter, type
		if event == "PLAYER_TARGET_CHANGED" then
			unit = "target"
		end
		if unit == "target" then
			filter = "HARMFUL"
			type = mod.DEBUFF
		elseif unit == "player" then
			filter = "HELPFUL"
			type = mod.BUFF
		else
			return
		end
		for id, data in pairs(spellInfo[type]) do
			data.ready = true
			data.duration = 0
			data.expirationTime = 0
			data.stack = 0
		end
		if UnitExists(unit) then -- don't update if the unit doesn't exist
			local info
			for id = 1, 40 do
				local name, _, _, stack, _,  duration, expirationTime = UnitAura(unit, id, filter.."|PLAYER")
				if name then
					spell = spellAlias[name]
					data = spellInfo[type][spell]
					if data then
						data.expirationTime = expirationTime
						data.duration = duration
						data.ready = false
						data.stack = stack
					end
				end
			end
		end
		if not scriptActive then
			mod.UpdateBars()
		end
	end

	function mod:UpdateCooldownStatus(event)
		for id, data in pairs(spellInfo[mod.COOLDOWN]) do
			local charges, _, start, duration = GetSpellCharges(id)
			if not charges then
				charges = 0
				start, duration, _ = GetSpellCooldown(id)
			end
			data.charges = charges + 1
			data.ready = duration == 0
			if data.ready then
				data.duration = 0
				data.start = 0
			else
				if duration and duration > gcd then
					data.duration = duration
					data.start = start or 0
				end
			end
		end
		if not scriptActive then
			mod.UpdateBars()
		end
	end
end

function mod:AnchorMoved(cbk, group, button)  
	db.point = { group:GetPoint() }
end

function mod:SetBarColor(bar, color)
	if not color then
		return
	end

	local rf = 0.5+color[1]/2
	local gf = 0.5+color[2]/2
	local bf = 0.5+color[3]/2
	bar:UnsetAllColors()

	if db.flashTimes and db.flashMode == 2 then
		local offset = gcd/10
		local interval = offset/(db.flashTimes*2)
		local endVal
		if db.showRemaining then
			endVal = interval
			interval = -interval
		else
			endVal = 1-interval
			offset = 1-offset
		end
		for val = offset, endVal,(interval*2) do
			bar:SetColorAt(val, color[1], color[2], color[3], color[4])
			if val ~= endVal then
				bar:SetColorAt(val+interval, rf, gf, bf, 1)
			end
		end
	end
	bar:SetColorAt(0, color[1], color[2], color[3], color[4])
	bar:SetColorAt(1, color[1], color[2], color[3], color[4])
	bar.overlayTexture:SetVertexColor(min(1, rf+0.2), min(1, gf+0.2), min(1, bf+0.2), bar.overlayTexture:GetAlpha())
end

function mod:PLAYER_REGEN_ENABLED()
	playerInCombat = false
	idleAlphaLevel = db.alphaOOC
end

function mod:PLAYER_REGEN_DISABLED()
	playerInCombat = true
	idleAlphaLevel = db.alphaReady
end

function mod:PLAYER_TALENT_UPDATE()
	mod:CreateBars()
end

function mod:ApplyProfile()
	bars:ClearAllPoints()
	if db.point then
		bars:SetPoint(unpack(db.point))
	else
		bars:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -300)
	end
	bars:ReverseGrowth(db.growup)
	mod:ToggleLocked(db.locked)
	mod:SetSoundFile()
	bars:SetSortFunction(bars.NOOP)
	mod:SetDefaultColors()
	mod:SetDefaultBars()
	mod:CreateBars()
	mod:SetFlashTimer()
	mod:SetTexture()
	mod:SetFont()
	mod:SetSize()
	mod:SetOrientation()
	bars:SetSortFunction(function(a, b)
		if db.reverseSort then
			return (a.sortValue or 10000) > (b.sortValue or 10000)
		else
			return (a.sortValue or 10000) < (b.sortValue or 10000)
		end
	end)
	bars:SetScale(db.scale)
	bars:SetSpacing(db.spacing)
	mod.UpdateBars()
	bars:SortBars()
end

function mod:OnProfileChanged(event, newdb)
	db = self.db.profile
	mod:UpdateLocalVariables()
	mod:ApplyProfile()
end

function mod:ToggleConfigDialog()
	InterfaceOptionsFrame_OpenToCategory(mod.text)
	InterfaceOptionsFrame_OpenToCategory(mod.main)
end

function mod:ToggleLocked(locked)
	if locked == nil then
		db.locked = not db.locked
	end
	if db.locked then
		bars:Lock()
	else
		bars:Unlock()
	end
	if db.hideAnchor then
		-- Show anchor if we're unlocked but lock it again if we're locked
		if db.locked then
			if bars.button:IsVisible() then
				bars:HideAnchor()
			end
		elseif not bars.button:IsVisible() then
			bars:ShowAnchor()
		end
	end
	bars:SortBars()
end

function mod:GetGlobalOption(info)
	return db[info[#info]]
end

function mod:SetGlobalOption(info, val)
	local var = info[#info]
	db[info[#info]] = val
	idleAlphaLevel = playerInCombat and db.alphaReady or db.alphaOOC
	mod.UpdateBars()
end

do
	-- DEV FUNCTION FOR CREATING PRESETS
	local presetParameters = {
		"orientation", "showLabel", "showTimer", "showIcon",
		"spacing", "length", "thickness", "iconScale",
		"animateIcons", "showRemaining",
		"alphaGCD", "alphaActive", "fadeAlpha",
		"flashMode", "flashTimes", "texture", "bgtexture",
		"timerOnIcon", "showSpark",
	}
	function mod:SavePreset(name, desc)
		local presets = BorrowedTimeDB.presets or {}
		presets[name] = {
			name = desc,
			data = {}
		}
		for _, param in ipairs(presetParameters) do
			presets[name].data[param] = db[param]
		end
		BorrowedTimeDB.presets = presets
	end
end

-- Override for the LibBars method. This makes it so the button doesn't move the bars when hidden or shown.
function mod:__ReverseGrowth(reverse)
	self.growup = reverse
	self.button:ClearAllPoints()
	if self.orientation % 2 == 0 then
		if reverse then
			self.button:SetPoint("TOPLEFT", self, "TOPRIGHT")
			self.button:SetPoint("BOTTOMLEFT", self, "BOTTOMRIGHT")
		else
			self.button:SetPoint("TOPRIGHT", self, "TOPLEFT")
			self.button:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT")
		end
	else
		if reverse then
			self.button:SetPoint("TOPLEFT", self, "BOTTOMLEFT")
			self.button:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT")
		else
			self.button:SetPoint("BOTTOMLEFT", self, "TOPLEFT")
			self.button:SetPoint("BOTTOMRIGHT", self, "TOPRIGHT")
		end
	end
	self:SortBars()
end

function mod:SortAllBars()
	hiddenBars:SortBars()
	bars:SortBars()
end