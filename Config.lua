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

local L = LibStub("AceLocale-3.0"):GetLocale("BorrowedTime", false)

-- upvalues
local PI = math.pi
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local unpack = unpack
local mod = BorrowedTime
local LibStub = LibStub
local R = LibStub("AceConfigRegistry-3.0")
local AC = LibStub("AceConfig-3.0")
local ACD = LibStub("AceConfigDialog-3.0")
local DBOpt = LibStub("AceDBOptions-3.0")
local LDBIcon = LibStub("LibDBIcon-1.0", true)
local AceGUIWidgetLSMlists = AceGUIWidgetLSMlists
local media = LibStub("LibSharedMedia-3.0")
local db, bars, cooldownbars

local defaultColors = {
	Background = {0.3, 0.3, 0.3, 0.5},
	Label = {1, 1, 1, 1},
	Timer = {1, 1, 1, 1},
}

local options = { 
	general = {
		type = "group",
		name = "General",
		get = "GetGlobalOption",
		handler = mod,
		order = 1,
		args = {
			showRemaining = {
				type = "toggle",
				name = L["Show remaining time"],
				desc = L["Instead showing the time elapsed on the cooldown, show the time remaining. This means that the bars will shrink as the cooldown lowers instead of grow."],
				width = "full",
				set = function (_, val)
					local old = db.showRemaining
					if old ~= val then
						db.showRemaining = val
						mod:FlipRemainingTimes()
					end
				end,
			},
			minimapIcon = {
				type = "toggle",
				name = L["Enable minimap icon"],
				desc = L["Show an icon to open the config at the Minimap"],
				get = function ()
					return not db.minimapIcon.hide
				end,
				set = function (info, value)
					db.minimapIcon.hide = not value
					LDBIcon[value and "Show" or "Hide"](LDBIcon, "BorrowedTime")
				end,
				disabled = function ()
					return not LDBIcon
				end,
			},
			locked = {
				type = "toggle",
				name = L["Lock bar positions"],
				width = "full",
				set = function ()
					mod:ToggleLocked()
				end,
			},
			growup = {
				type = "toggle",
				name = L["Reverse growth direction"],
				desc = L["Reverse the order in which bars are added relative to the anchor."], 
				width = "full",
				set = function (_, val)
					db.growup = val
					bars:ReverseGrowth(val)
				end, 
			},
			hideInactiveDebuff = {
				type = "toggle",
				name = L["Hide inactive buffs and debuffs"],
				desc = L["Hide bars containing buffs or debuffs that aren't applied instead of showing them transparently"],
				width = "full",
				set = function (_, val)
					db.hideInactiveDebuff = val
					mod:CreateBars()
				end,
			},
			hideAnchor = {
				type = "toggle",
				name = L["Hide anchor when bars are locked."],
				width = "full",
				set = function ()
					db.hideAnchor = not db.hideAnchor
					if db.locked and db.hideAnchor then
						bars:HideAnchor()
					else
						bars:ShowAnchor()
					end
					mod:info("The anchor will be %s when the bars are locked.", db.hideAnchor and "hidden" or "shown") 
				end,
			},
			sound = {
				type = 'select',
				dialogControl = 'LSM30_Sound',
				name = L["Alert sound effect"],
				desc = L["The sound effect to play when the sound alert trigger occurs."],
				values = AceGUIWidgetLSMlists.sound,
				set = "SetSoundFile",
				disabled = function ()
					return db.soundOccasion == 1
				end,
				order = 100,
			},
			soundOccasion = {
				type = "select",
				name = L["Alert sound trigger"],
				desc = L["When to play the alert sound: On GCD; play when the remaining cooldown goes below the global cooldown. On readiness; play when an ability becomes ready for use."],
				values = {
					L["Never"], L["On GCD"], L["On readiness"]
				},
				set = function (_, val)
					db.soundOccasion = val
				end,
				order = 90,
			},
			preset = {
				type = "select", 
				name = L["Load preset"],
				desc = L["Presets are primarily here to give you a few ideas on how you can configure the bars. Note that the presets do now change font, texture or color options. The global scale is also not changed."],
				values = "GetPresetList",
				order = 0,
				set = function (_, preset)
					if db.preset ~= preset then
						db.preset = preset
						for var, val in pairs(mod.presets[preset].data) do
							db[var] = val
						end
						mod:ApplyProfile()
						mod:NotifyChange()
					end
				end,
			},
		},
	},
	colors = {
		type = "group",
		name = L["Colors"],
		order = 9,
		handler = mod,
		set = "SetColorOpt",
		get = "GetColorOpt",
		args = {
			Label = {
				type = "color",
				name = L["Label"],
				desc = L["Color used for the text label."],
				hasAlpha = true,
				order = 1,
			},
			Timer = {
				type = "color",
				name = L["Timer"],
				desc = L["Color used for the timer text."],
				hasAlpha = true,
				order = 2,
			},
			Background = {
				type = "color",
				name = L["Background"],
				desc = L["Color used for background texture."],
				hasAlpha = true,
				order = 3,
			},
		},
	},
	deco = {
		type = "group",
		name = L["Decoration and Effects"],
		handler = mod,
		get = "GetGlobalOption",
		args = {
			showLabel = {
				type = "toggle",
				name = L["Show labels"],
				desc = L["Show labels on the bars indicating the ability name. Note the timer cannot be shown on the icon while labels are enabled."],
				set = function (_, val)
					db.showLabel = val mod:UpdateLabels()
				end,
				order = 10,
			},
			showTimer = {
				type = "toggle",
				name = L["Show timer"],
				set = function (_, val)
					db.showTimer = val mod:UpdateLabels()
				end,
				order = 20,
			},
			secondsOnly = {
				type = "toggle",
				name = L["Seconds only"],
				desc = L["Normally the time is shown with one decimal place when the remaining cooldown is less than the global cooldown. If this toggled on, only seconds will be shown."],
				set = function (_, val)
					db.secondsOnly = val mod:UpdateLabels()
				end,
				disabled = function ()
					return not db.showTimer
				end,
				order = 24,
			},
			timerOnIcon = {
				type = "toggle",
				name = L["Show timer on icon"],
				desc = L["Show the countdown timer on top of the icon instead of on the bar. This option is only available when labels are hidden."],
				set = function (_, val)
					db.timerOnIcon = val mod:UpdateLabels()
				end,
				disabled = function ()
					return db.showLabel or not (db.showTimer and db.showIcon)
				end,
				order = 25,
			},
			showIcon = {
				type = "toggle",
				name = L["Show icons"],
				set = function (_, val)
					db.showIcon = val mod:UpdateIcons()
				end,
				order = 30,
			},
			animateIcons = {
				type = "toggle",
				name = L["Animate icons"],
				desc = L["If enabled, the icons will move with the bar. If the bar texture is hidden, you'll get a display simply showing the cooldown using icons."],
				set = function (_, val)
					db.animateIcons = val mod:SetOrientation()
				end,
				disabled = function ()
					return not db.showIcon
				end,
				order = 35,
			},
			showSpark = {
				type = "toggle",
				name = L["Show spark"],
				desc = L["Toggle whether or not to show the spark on active bars."],
				set = function (_, val)
					db.showSpark = val mod:SetOrientation()
				end,
				disabled = function ()
					return db.animateIcons
				end,
				order = 38,
			},
			flashMode = {
				type = "select",
				name = L["Flash mode"],
				desc = L["Type of flashing to use to indicate imminent readiness."],
				values = {
					L["None"],
					L["Color Flash"],
					L["Alpha Flash"]
				},
				set = function (_, val)
					db.flashMode = val mod:SetFlashTimer()
				end,
				order = 40,
			},
			flashTimes = {
				type = "range",
				name = L["Number of flashes"],
				desc = L["Number of times to flash bars when the remaining is less than the GCD. Set to zero to disable flashing."],
				min = 1,
				max = 10,
				step = 1,
				set = "SetFlashTimer",
				hidden = function ()
					return db.flashMode == 1
				end,
				order = 50,
			},
			readyFlash = {
				type = "toggle",
				name = L["Flash when ready"],
				desc = L["When a cooldown finishes, flash the bar as an extra notification source."],
				set = "SetReadyFlashOpt",
				order = 60,
			},
			readyFlashDuration = {
				type = "range",
				name = L["Ready flash duration"],
				desc = L["The time in seconds that the bar should flash when a cooldown finishes."],
				set = "SetReadyFlashOpt",
				min = 0.01,
				max = 2.5,
				step = 0.001,
				disabled = function ()
					return not db.readyFlash
				end,
				order = 70,
			},
		},
	},
	alpha = {
		type = "group",
		name = L["Alpha Settings"],
		handler = mod,
		get = "GetGlobalOption",
		args = {
			alphaOOC = {
				type = "range",
				name = L["Out of combat alpha"],
				desc = L["Alpha level for available abilities when out of combat."],
				width = "full",
				min = 0,
				max = 1,
				step = 0.01,
				set = "SetGlobalOption",
				order = 100,
			},
			alphaReady = {
				type = "range",
				name = L["In-Combat available ability alpha"],
				desc = L["Alpha level of available abilities when in combat."],
				width = "full",
				min = 0,
				max = 1,
				step = 0.01,
				set = "SetGlobalOption",
				order = 110,
			},
			alphaGCD = {
				type = "range",
				name = L["In-GCD cooldown alpha"],
				desc = L["Alpha level when the remaining cooldown is shorter the global cooldown."],
				width = "full",
				min = 0,
				max = 1,
				step = 0.01,
				set = "SetGlobalOption",
				order = 120,
			},
			alphaActive = {
				type = "range",
				name = L["Out-of-GCD cooldown alpha"],
				desc = L["Alpha level when the remaining cooldown is longer than the global cooldown."],
				width = "full",
				min = 0,
				max = 1,
				step = 0.01,
				set = "SetGlobalOption",
				order = 130,
			},
			fadeAlpha = {
				type = "toggle",
				name = L["Fade alpha level of cooldowns"],
				desc = L["Fade alpha level between the in GCD and out of GCD alpha level. This can be used to make the cooldown displays become incrementally more visible as the cooldown decreases."], 
				width = "full",
				set = "SetGlobalOption",
				order = 140,
			},
			fadeAlphaGCD = {
				type = "toggle",
				name = L["Fade alpha from gcd to available"],
				desc = L["Fade the alpha level between the GCD level and the available level. This option is ignored if the alpha flash notification is enabled."],
				width = "full",
				set = "SetGlobalOption",
				disabled = function ()
					return db.flashMode == 3
				end,
				order = 145,
			}
		}
	},
	sizing = {
		type = "group",
		name = L["Bar Layout"],
		order = 4,
		handler = mod,
		get = "GetGlobalOption",
		args = {
			length = {
				type = "range",
				name = L["Length"],
				width = "full",
				min = 20,
				max = 500,
				step = 0.01,
				set = function (_, val)
					db.length = val
					mod:SetSize()
				end,
				order = 1
			}, 
			thickness = {
				type = "range",
				name = L["Thickness"],
				width = "full",
				min = 1,
				max = 150,
				step = 0.01,
				set = function (_, val)
					db.thickness = val
					mod:SetSize()
				end,
				order = 2
			}, 
			spacing = {
				type = "range",
				name = L["Spacing"],
				width = "full",
				min = -30,
				max = 30,
				step = 0.01,
				set = function (_, val)
					db.spacing = val
					bars:SetSpacing(val)
				end,
				order = 3
			}, 
			scale = {
				type = "range",
				name = L["Overall Scale"],
				width = "full",
				min = 0.01,
				max = 5,
				step = 0.01,
				set = function (_, val)
					db.scale = val
					bars:SetScale(val)
				end,
				order = 4
			},
			iconScale = {
				type = "range",
				name = L["Icon Scale"],
				width = "full",
				min = 0.01,
				max = 50,
				step = 0.01,
				set = function (_ ,val)
					db.iconScale = val
					mod:SetIconScale(val)
				end,
				order = 4
			},
			orientation = {
				type = "select",
				name = L["Orientation"],
				values = {
					"Horizontal, Left",
					"Vertical, Bottom",
					"Horizontal, Right",
					"Vertical, Top"
				},
				set = function (_, val)
					db.orientation = val
					mod:SetOrientation(val)
				end,
				order = 5,
			},
		},
	},
	looks = {
		type = "group",
		name = L["Font and Texture"],
		order = 3,
		handler = mod,
		get = "GetGlobalOption",
		args = {
			texture = {
				type = 'select',
				dialogControl = 'LSM30_Statusbar',
				name = L["Texture"],
				desc = L["The texture used for active bars."],
				values = AceGUIWidgetLSMlists.statusbar, 
				set = function (_, val)
					db.texture = val
					mod:SetTexture()
				end,
				order = 3
			},
			bgtexture = {
				type = 'select',
				dialogControl = 'LSM30_Statusbar',
				name = L["Background Texture"],
				desc = L["The background texture for the bars."],
				values = AceGUIWidgetLSMlists.statusbar, 
				set = function (_, val)
					db.bgtexture = val
					mod:SetTexture()
				end,
				order = 4
			},
			font = {
				type = 'select',
				dialogControl = 'LSM30_Font',
				name = L["Font"],
				desc = L["Font used on the bars"],
				values = AceGUIWidgetLSMlists.font, 
				set = function (_, key)
					db.font = key
					mod:SetFont()
				end,
				order = 2,
			},
			fontsize = {
				order = 1, 
				type = "range",
				width = "full",
				name = L["Font size"],
				min = 1,
				max = 30,
				step = 0.01,
				set = function (_, val)
					db.fontsize = val
					mod:SetFont()
				end,
				order = 1
			},
		},
	},
	cooldownbar = {
		type = "group",
		name = L["Bar #"],
		args = {
			spell = {
				type = "input",
				width = "full",
				name = L["Spell"],
				desc = L["Name of the spell to track."],
				order = 20,
			},
			color = {
				type = "color",
				name = L["Color"],
				desc = L["Color used for bar."],
				hasAlpha = true,
				get = function (info)
					local var = info[#info]
					local id = tonumber(info[#info-1])
					return unpack(db.bars[id][var])
				end,
				set = function (info, r, g, b, a)
					local var = info[#info]
					local id = tonumber(info[#info-1])
					local data = db.bars[id]

					data[var] = {r, g, b, a}
					mod:CreateBars()
				end,
				order = 25,
			},
			type = {
				type = "select",
				name = L["Type"],
				desc = L["The property of the spell that should be tracked."],
				values = {
					"Cooldown",
					"Debuff",
					"Buff",
				},
				order = 30,
			},
			hide = {
				type = "toggle",
				width = "full",
				name = L["Hide bar"],
				desc = L["Toggle visibility of this bar."],
				order = 35,
			},
			delete = {
				type = "execute",
				width = "half",
				name = L["Delete"],
				desc = L["Delete this bar"],
				func = "DeleteBar",
			},			
			moveup = {
				type = "execute",
				width = "half",
				name = L["Up"],
				desc = L["Move this bar up"],
				func = "MoveBarUp",
				disabled = function (info)
					return tonumber(info[#info-1]) <= 1
				end,
			},			
			movedown = {
				type = "execute",
				width = "half",
				name = L["Down"],
				desc = L["Move this bar down"],
				func = "MoveBarDown",
				disabled = function (info)
					return tonumber(info[#info-1]) >= #db.bars
				end,
			},			
		},
	},
	bars = {
		type = "group",
		name = L["Bar Configuration"],
		handler = mod,
		set = "SetBarOption",
		get = "GetBarOption",
		args = {
			newbar = {
				type = "execute",
				name = L["Add a new bar"],
				desc = L["Create a new bar."],
				func = "AddNewBar",
			},			
		}
	}
}

mod.options = options


function mod:AddNewBar()
	db.bars[#db.bars+1] = {
		type = mod.COOLDOWN,
		spell = L["New bar"],
		color = {1, 1, 1, 1},
	}
	mod:CreateBars()
end

function mod:DeleteBar(info)
	local id = tonumber(info[#info-1])
	tremove(db.bars, id)
	mod:CreateBars()
end

function mod:MoveBarUp(info)
	local id = tonumber(info[#info-1])
	if id > 1 then
		db.bars[id], db.bars[id - 1] = db.bars[id - 1], db.bars[id]
	end
	mod:CreateBars()
end

function mod:MoveBarDown(info)
	local id = tonumber(info[#info-1])
	if id < #db.bars then
		db.bars[id], db.bars[id + 1] = db.bars[id + 1], db.bars[id]
	end
	mod:CreateBars()
end

function mod:GetBarOption(info)
	local var = info[#info]
	local id  = tonumber(info[#info-1])
	return db.bars[id][var]
end

function mod:SetBarOption(info, val)
	local var = info[#info]
	local id = tonumber(info[#info-1])
	local data = db.bars[id]

	data[var] = val
	mod:CreateBars()
end

do
	local configPanes = {}

	function mod:OptReg(optname, tbl, dispname, cmd, ownSection)
		local regtable
		if dispname then
			optname = "Borrowed Time "..optname
			AC:RegisterOptionsTable(optname, tbl, cmd)
			if not cmd then
				if ownSection then
					regtable = ACD:AddToBlizOptions(optname, L["Borrowed Time"].." "..dispname)
				else
					regtable = ACD:AddToBlizOptions(optname, dispname, L["Borrowed Time"])
				end
			end
		else
			AC:RegisterOptionsTable(optname, tbl, cmd)
			if not cmd then
				regtable = ACD:AddToBlizOptions(optname, L["Borrowed Time"])
			end
		end
		configPanes[#configPanes+1] = optname
		return regtable
	end

	function mod:NotifyChange()
		for _, name in ipairs(configPanes) do
			R:NotifyChange(name)
		end
	end

	function mod:SetupBarOptions(reload)
		local args = options.bars.args
		for id in pairs(args) do
			if id ~= "newbar" then
				args[id] = nil
			end
		end
		if db.bars then
			for id, data in ipairs(db.bars) do
				local bar = {}
				bar.order = id
				for key, val in pairs(options.cooldownbar) do
					bar[key] = val
				end
				bar.name = data.title
				args[tostring(id)] = bar
			end
		end

		if reload then 
			R:NotifyChange("Borrowed Time: Bar Configuration")
		else
			mod:OptReg(": Bar Configuration", options.bars, L["Bar Configuration"])
		end
	end
end

function mod:SetupOptions()
	options.profile = DBOpt:GetOptionsTable(self.db)
	mod.main = mod:OptReg("Borrowed Time", options.general)
	mod:OptReg(": Bar Alpha", options.alpha, L["Alpha Levels"])
	mod:OptReg(": Bar Colors", options.colors, L["Colors"])
	mod:OptReg(": Bar Decorations", options.deco, L["Decorations"])
	mod:OptReg(": Bar Layout", options.sizing, L["Layout and Sorting"])
	mod:OptReg(": Font & Texture", options.looks, L["Font & Texture"])
	mod.text = mod:OptReg(": Profiles", options.profile, L["Profiles"])
	mod:SetupBarOptions()
	mod:OptReg("Borrowed Time CmdLine", {
		name = "Command Line",
		type = "group",
		args = {
			config = {
				type = "execute",
				name = L["Show configuration dialog"],
				func = function ()
					mod:ToggleConfigDialog()
				end,
				dialogHidden = true
			},
		}
		}, nil,  { "btime", "borrowedtime" })
end

function mod:UpdateLocalVariables()
	db = mod.db.profile
	bars = mod.bars
	cooldownbars = mod.cooldownbars
end

function mod:SetIconScale(val)
	for _, bars in pairs(cooldownbars) do
		for _, bar in pairs(bars) do
			if bar then
				bar.icon:SetWidth(db.thickness * val)
				bar.icon:SetHeight(db.thickness * val)
			end
		end
	end
end

function mod:SetTexture()
	bars:SetTexture(media:Fetch("statusbar", db.texture))
	for _, bars in pairs(cooldownbars) do
		for _, bar in pairs(bars) do
			if bar then
				bar.bgtexture:SetTexture(media:Fetch("statusbar", db.bgtexture))
			end
		end
	end
end

function mod:SetFont()
	bars:SetFont(media:Fetch("font", db.font), db.fontsize)
end

function mod:UpdateIcons()
	for _, bars in pairs(cooldownbars) do
		for _, bar in pairs(bars) do
			if bar then
				if db.showIcon and db.animateIcons then
					bar.spark:SetAlpha(0)
				else
					bar.spark:SetAlpha(1)
				end
				if db.showIcon then
					bar:ShowIcon()
				else
					bar:HideIcon()
				end
			end
		end
	end
end

function mod:UpdateLabels()
	for _, bars in pairs(cooldownbars) do
		for _, bar in pairs(bars) do
			if bar then
				if db.showLabel then
					bar:ShowLabel()
				else
					bar:HideLabel()
				end
				if db.showTimer then
					bar:ShowTimerLabel()
					if db.timerOnIcon and not db.showLabel then
						bar.timerLabel:ClearAllPoints()
						bar.timerLabel:SetPoint("CENTER", bar.icon, "CENTER")
					else
						bar:UpdateOrientationLayout()
					end
				else
					bar:HideTimerLabel()
				end
			end
		end
	end
end

function mod:RefreshBarColors()
	local bg = db.colors.Background
	for id, bars in pairs(cooldownbars) do
		for _, bar in pairs(bars) do
			if bar then 
				local bdb = db.bars[id]
				bar:SetBackgroundColor(bg[1], bg[2], bg[3], bg[4])
				bar.label:SetTextColor(unpack(db.colors.Label))
				bar.timerLabel:SetTextColor(unpack(db.colors.Timer))
			end
		end
	end
end

function mod:SetColorOpt(arg, r, g, b, a)
	local color = arg[#arg]
	db.colors[color][1] = r
	db.colors[color][2] = g
	db.colors[color][3] = b
	db.colors[color][4] = a
	mod:RefreshBarColors()
end

function mod:GetColorOpt(arg)
	return unpack(db.colors[arg[#arg]])
end

function mod:SetReadyFlashOpt(info, val)
	db[info[#info]] = val
	mod._readyFlash2 = db.readyFlashDuration/2
end

function mod:SetDefaultColors()
	-- Populate default colors
	if not db.colors then
		db.colors = defaultColors
	else
		for color, val in pairs(defaultColors) do
			if not db.colors[color] then
				db.colors[color] = val
			end
		end
	end
end

function mod:SetBarLabel(id, title, stack)
	local label	
	if mod._vertical then 
		label = string.upper(title:gsub("%s*(%w)%w*%s*", "%1"))
	else
		label = title
		if stack and stack > 0 then
			label = label.." ("..stack..")"
		end
	end
	for _, bar in pairs(cooldownbars[id]) do
		if bar then
			bar:SetLabel(label)
		end
	end
end

function mod:SetOrientation(orientation)
	if not orientation then
		orientation = db.orientation
	end
	bars:SetOrientation(orientation)
	mod._vertical = (orientation == 2 or orientation == 4)
	for id, data in ipairs(db.bars) do
		if (cooldownbars[id]) then
			for _, bar in pairs(cooldownbars[id]) do
				if bar then 
					if db.showIcon and db.animateIcons then
						bar.icon:ClearAllPoints()
						bar.icon:SetPoint("CENTER", bar.spark)
						bar.spark:SetAlpha(0)
					else
						bar.spark:SetAlpha(db.showSpark and 1 or 0)
					end
					mod:SetBarLabel(id, data.title)
				end
			end
		end
	end
	mod:SetIconScale(db.iconScale)
	mod:UpdateLabels()
end

function mod:SetSize()
	bars:SetThickness(db.thickness)
	bars:SetLength(db.length)
	bars:SortBars()
	mod:SetIconScale(db.iconScale)
end

-- Set up the default bars
function mod:SetDefaultBars()
	if not db.bars then
		db.bars = {}
	end
	mod:CreateBars()
end

function mod:SetFlashTimer(_, val)
	if val then
		db.flashTimes = val
	end
	if db.flashTimes and db.flashTimes > 0 and db.flashMode == 3 then
		mod.flashTimer = db.flashTimes * 2 * PI
	else
		mod.flashTimer = nil
	end
	mod:RefreshBarColors()
end

function mod:SetSoundFile(_, val)
	if val then
		db.sound = val
	end
	mod.soundFile = media:Fetch("sound", db.sound)
end