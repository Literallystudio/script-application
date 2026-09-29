-// is this enough comments

--// services

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService") --// only used for GetValue, the actual tweening is done by hand further down

local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")
local Config = require(ClientModules:WaitForChild("Config")) --// every tweakable number lives in here so i dont have to touch this file to tune the camera

local Player = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local MainUI = PlayerGui:WaitForChild("MainUI") --// waitforchild cus the gui can load after this module gets required

local CameraHandle = {}

--// easing

local EaseStyleNames = { --// chart events name their eases as strings so this turns them into enums
	linear = Enum.EasingStyle.Linear,
	sine = Enum.EasingStyle.Sine,
	quad = Enum.EasingStyle.Quad,
	cubic = Enum.EasingStyle.Cubic,
	quart = Enum.EasingStyle.Quart,
	quint = Enum.EasingStyle.Quint,
	expo = Enum.EasingStyle.Exponential,
	circ = Enum.EasingStyle.Circular,
	back = Enum.EasingStyle.Back,
	bounce = Enum.EasingStyle.Bounce,
	elastic = Enum.EasingStyle.Elastic,
	classic = Enum.EasingStyle.Quad, --// classic is just quad
}

local function ParseEase(easeName)
	if not easeName or easeName == "" then
		return { Style = Enum.EasingStyle.Quad, Direction = Enum.EasingDirection.InOut } --// nothing given so use the default
	end

	local lower = string.lower(easeName) --// so QuadOut and quadout both work
	local direction = Enum.EasingDirection.InOut
	local styleKey = lower

	if string.sub(lower, -5) == "inout" then --// has to be checked first cus inout also ends with "out"
		direction = Enum.EasingDirection.InOut
		styleKey = string.sub(lower, 1, -6) --// chop the direction off the end so only the style name is left
	elseif string.sub(lower, -2) == "in" then
		direction = Enum.EasingDirection.In
		styleKey = string.sub(lower, 1, -3)
	elseif string.sub(lower, -3) == "out" then
		direction = Enum.EasingDirection.Out
		styleKey = string.sub(lower, 1, -4)
	end

	local style = EaseStyleNames[styleKey] or Enum.EasingStyle.Quad --// a typo in a chart shouldnt error, just fall back to quad
	return { Style = style, Direction = direction }
end

--// ui refs

local CameraRoot = MainUI:FindFirstChild("CameraRoot") --// frame holding the whole playfield, moving and scaling this is the "camera"
local Scale = nil
if CameraRoot then
	Scale = CameraRoot:FindFirstChildOfClass("UIScale") --// zoom is a uiscale so every child scales with it for free
end

local FocusPoints = nil
if CameraRoot then
	FocusPoints = CameraRoot:FindFirstChild("FocusPoints") --// markers inside the root so they move around with it
end

-- char mapping: 0 = Player, 1 = Opponent, 2 = Center
local FocusTargetByChar = {}
if FocusPoints then
	local player = FocusPoints:FindFirstChild("PlayerFocus")
	local opponent = FocusPoints:FindFirstChild("OpponentFocus")
	local center = FocusPoints:FindFirstChild("CenterFocus")
	if player then
		FocusTargetByChar[0] = player
	end
	if opponent then
		FocusTargetByChar[1] = opponent
	end
	if center then
		FocusTargetByChar[2] = center
	end
end

local FocusAnchor = Config.CameraFocusAnchor or UDim2.fromScale(0.5, 0.5) --// spot on screen the focused marker gets pulled to, center by default

local BasePosition = UDim2.new()
if CameraRoot then
	BasePosition = CameraRoot.Position --// remembered so Reset can put the root back where it started
end

local function GetLocalFraction(target)
	if not CameraRoot then
		return Vector2.new(0.5, 0.5)
	end
	local rootAbsPos = CameraRoot.AbsolutePosition
	local rootAbsSize = CameraRoot.AbsoluteSize
	if rootAbsSize.X <= 0 or rootAbsSize.Y <= 0 then
		return Vector2.new(0.5, 0.5) --// ui hasnt laid out yet so dividing below would give inf, just say center
	end
	local targetCenter = target.AbsolutePosition + target.AbsoluteSize * 0.5 --// absolute space so it doesnt matter how deep the marker is parented
	return Vector2.new(
		(targetCenter.X - rootAbsPos.X) / rootAbsSize.X, --// 0 to 1 across the root instead of pixels, stays valid at any zoom
		(targetCenter.Y - rootAbsPos.Y) / rootAbsSize.Y
	)
end

--// animation, done by hand instead of tweenservice cus it has to follow the song clock (not real time) or pausing desyncs it

local function StartAnim(currentValue, target, nowMS, durationSeconds, ease)
	if durationSeconds <= 0 then
		return nil --// no anim needed, the caller snaps the value itself
	end
	return {
		from = currentValue, --// starts from wherever it is right now so cutting a pan off mid way doesnt jump
		to = target,
		startMS = nowMS,
		durationMS = durationSeconds * 1000, --// song time is in ms
		ease = ease,
	}
end

local function EvalAnim(anim, fallback, nowMS)
	if not anim then
		return fallback, nil --// nothing running so the value just stays
	end
	local elapsed = nowMS - anim.startMS
	if elapsed >= anim.durationMS then
		return anim.to, nil --// done, land exactly on the target and hand back nil so the anim clears itself
	end
	local alpha = 1
	if anim.durationMS > 0 then
		alpha = math.clamp(elapsed / anim.durationMS, 0, 1) --// clamp for when song time jumps back a little
	end
	local eased = TweenService:GetValue(alpha, anim.ease.Style, anim.ease.Direction) --// just runs the curve, no tween object gets made
	return anim.from + (anim.to - anim.from) * eased, anim --// plain lerp with the eased alpha, anim returned so it keeps running
end

--// state

local LocalX, LocalY = 0.5, 0.5 --// which spot of the root (0 to 1) sits under the anchor, middle to start
local LocalXAnim = nil
local LocalYAnim = nil

local OffsetX = FocusAnchor.X.Offset --// pixel nudge on top of the focus, comes from x and y in the event
local OffsetY = FocusAnchor.Y.Offset
local OffsetXAnim = nil
local OffsetYAnim = nil

local HasFocused = false --// first focus snaps instead of panning or the camera would slide in from the middle at song start

local BaseZoom = 1 --// zoom from ZoomCamera events
local BaseZoomAnim = nil

local FocusZoomVal = 1 --// separate zoom from focusing, multiplied with BaseZoom later so they dont fight over one number
local FocusZoomAnim = nil

local BPM = Config.DefaultBPM or 100
local MsPerBeat = 60000 / BPM --// 60000 ms in a minute
local LastBeatIndex = -1 --// last beat already handled so a bump only starts once per beat
local BumpStartTimeMS = -1e9 --// way in the past so theres no bump before the first beat

local BaseBumpAmount = Config.CameraBeatBumpAmount or 0.015
local BaseBumpEvery = math.max(Config.CameraBeatBumpEvery or 1, 1) --// min 1 or the modulo below would divide by 0

local BopIntensity = 1 --// multiplier on the bump, events change it
local BopRate = BaseBumpEvery --// bump every x beats, also event controlled

local PanSpeedMultiplier = 1 --// pan duration gets divided by this so bigger means faster pans

local MinRenderedScale = 0
local MaxRenderedScale = math.huge --// no clamp until SetScaleClamp gets called

local LastKnownSongTimeMS = 0 --// saved every Update so the actions below know what time to start their anims at

--// beat bump

local function EvaluateBump(currentSongTimeMS)
	if MsPerBeat <= 0 then
		return 0 --// bad bpm, dont divide by it
	end
	local bumpEvery = math.max(BopRate, 1)
	local beatIndex = math.floor(currentSongTimeMS / MsPerBeat) --// which beat we are on right now
	if beatIndex ~= LastBeatIndex then --// only runs on the frame the beat changes
		LastBeatIndex = beatIndex
		if beatIndex % bumpEvery == 0 then --// skips beats when bumpEvery is more than 1
			BumpStartTimeMS = beatIndex * MsPerBeat --// exact beat time instead of now so one laggy frame doesnt shift the whole bump
		end
	end
	local elapsed = currentSongTimeMS - BumpStartTimeMS
	if elapsed < 0 or elapsed >= MsPerBeat then
		return 0 --// a bump only lasts one beat
	end
	local alpha = elapsed / MsPerBeat
	local decay = 1 - TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) --// flipped so it starts full and eases down to 0
	return BaseBumpAmount * BopIntensity * decay
end

--// camera actions

local function FocusCamera(v, maxDurationSeconds)
	if not CameraRoot then
		return
	end

	local char = v.char or 0 --// no char in the event means player
	local target = FocusTargetByChar[char]
	if not target then
		warn(string.format("CameraHandle: no FocusPoints marker for char=%s - ignoring FocusCamera.", tostring(char))) --// warn not error, one bad event shouldnt kill the song
		return
	end

	local frac = GetLocalFraction(target)
	local targetLocalX, targetLocalY = frac.X, frac.Y
	local targetOffsetX = FocusAnchor.X.Offset + (v.x or 0) --// x and y in the event push the camera off the marker a bit
	local targetOffsetY = FocusAnchor.Y.Offset + (v.y or 0)
	local targetFocusZoom = Config.CameraFocusZoom or 1

	local nowMS = LastKnownSongTimeMS

	if not HasFocused then
		HasFocused = true
		LocalX, LocalY = targetLocalX, targetLocalY
		OffsetX, OffsetY = targetOffsetX, targetOffsetY
		FocusZoomVal = targetFocusZoom
		LocalXAnim, LocalYAnim, OffsetXAnim, OffsetYAnim, FocusZoomAnim = nil, nil, nil, nil, nil --// wipe old anims or they would drag it away from the snap
		return
	end

	local rawDuration = Config.CameraDefaultPanDuration or 4
	if v.duration ~= nil then
		rawDuration = v.duration --// the event can override the default pan time
	end

	if rawDuration <= 0 then
		LocalX, LocalY = targetLocalX, targetLocalY
		OffsetX, OffsetY = targetOffsetX, targetOffsetY
		FocusZoomVal = targetFocusZoom
		LocalXAnim, LocalYAnim, OffsetXAnim, OffsetYAnim, FocusZoomAnim = nil, nil, nil, nil, nil
		return
	end

	local duration = rawDuration / PanSpeedMultiplier
	if maxDurationSeconds ~= nil then
		local safeMax = math.max(maxDurationSeconds * 0.9, 0.05) --// 90% of the gap to the next focus so the pan ends before the next one starts, 0.05 floor so it never hits 0
		if duration > safeMax then
			duration = safeMax
		end
	end

	local ease = ParseEase(v.ease or Config.CameraDefaultPanEase)

	LocalXAnim = StartAnim(LocalX, targetLocalX, nowMS, duration, ease) --// all five start together with the same duration and ease so it moves as one
	LocalYAnim = StartAnim(LocalY, targetLocalY, nowMS, duration, ease)
	OffsetXAnim = StartAnim(OffsetX, targetOffsetX, nowMS, duration, ease)
	OffsetYAnim = StartAnim(OffsetY, targetOffsetY, nowMS, duration, ease)
	FocusZoomAnim = StartAnim(FocusZoomVal, targetFocusZoom, nowMS, duration, ease)
end

local function ZoomCamera(v)
	if not Scale then
		return
	end

	local zoom = v.zoom or 1
	local duration = v.duration or 0
	local nowMS = LastKnownSongTimeMS

	if duration <= 0 then
		BaseZoom = zoom
		BaseZoomAnim = nil
		return
	end

	local ease = ParseEase(v.ease)
	BaseZoomAnim = StartAnim(BaseZoom, zoom, nowMS, duration, ease)
end

local function SetCameraBop(v)
	if v.intensity ~= nil then
		BopIntensity = v.intensity --// only touch what the event actually sent
	end
	if v.rate ~= nil then
		BopRate = math.max(v.rate, 1)
	end
end

--// events

local EventHandlers = { --// FocusCamera isnt in here cus it needs to know when the next focus is, Update deals with it
	ZoomCamera = function(v)
		if typeof(v) == "table" then --// bad chart data (like a plain number) just gets ignored
			ZoomCamera(v)
		end
	end,
	SetCameraBop = function(v)
		if typeof(v) == "table" then
			SetCameraBop(v)
		end
	end,
}

local Events = {}
local EventStep = 1 --// index of the next event that hasnt run yet

--// public api

CameraHandle.LoadEvents = function(events)
	Events = events or {} --// expects them sorted by time, Update reads them in order
	EventStep = 1
end

CameraHandle.SetPanSpeedMultiplier = function(multiplier)
	PanSpeedMultiplier = math.max(multiplier, 0.01) --// floor so it never divides by 0
end

CameraHandle.SetScaleClamp = function(minScale, maxScale)
	MinRenderedScale = math.min(minScale, maxScale) --// min and max so passing them swapped doesnt break the clamp
	MaxRenderedScale = math.max(minScale, maxScale)
end

CameraHandle.SetBPM = function(bpm)
	if bpm and bpm > 0 then
		BPM = bpm
	else
		BPM = Config.DefaultBPM or 100
	end
	MsPerBeat = 60000 / BPM
	LastBeatIndex = -1 --// old beat index means nothing at the new bpm
	BumpStartTimeMS = -1e9
end

CameraHandle.Update = function(currentSongTimeMS)
	LastKnownSongTimeMS = currentSongTimeMS --// set first, the actions below read it for their start time

	local event = Events[EventStep]
	while event and currentSongTimeMS >= event.t do --// while and not if cus more than one event can land on the same frame
		if event.e == "FocusCamera" then
			local v = event.v
			local focusValue

			if typeof(v) == "number" then
				focusValue = { char = v } --// shorthand event, just the char number
			elseif typeof(v) == "table" then
				focusValue = v
			else
				focusValue = {} --// junk value falls back to defaults
			end

			local maxGapSeconds = nil
			for i = EventStep + 1, #Events do --// look ahead for the next focus event only, other types dont matter here
				local nextEvent = Events[i]
				if nextEvent.e == "FocusCamera" then
					maxGapSeconds = (nextEvent.t - event.t) / 1000 --// ms to seconds
					break
				end
			end

			FocusCamera(focusValue, maxGapSeconds)
		else
			local handler = EventHandlers[event.e]
			if handler then
				handler(event.v)
			else
				warn(string.format("CameraHandle: unknown event type '%s' at t=%s", tostring(event.e), tostring(event.t))) --// misspelled event names show up in output instead of silently doing nothing
			end
		end
		EventStep = EventStep + 1 --// moving the step forward is what stops an event from running twice
		event = Events[EventStep]
	end

	if not CameraRoot then
		return --// events still got consumed above so the step stays in sync
	end

	LocalX, LocalXAnim = EvalAnim(LocalXAnim, LocalX, currentSongTimeMS) --// each eval gives back the new value and the anim (nil once finished) so the anim variable clears itself
	LocalY, LocalYAnim = EvalAnim(LocalYAnim, LocalY, currentSongTimeMS)
	OffsetX, OffsetXAnim = EvalAnim(OffsetXAnim, OffsetX, currentSongTimeMS)
	OffsetY, OffsetYAnim = EvalAnim(OffsetYAnim, OffsetY, currentSongTimeMS)
	BaseZoom, BaseZoomAnim = EvalAnim(BaseZoomAnim, BaseZoom, currentSongTimeMS)
	FocusZoomVal, FocusZoomAnim = EvalAnim(FocusZoomAnim, FocusZoomVal, currentSongTimeMS)

	local bump = EvaluateBump(currentSongTimeMS)
	local totalScale = math.clamp(BaseZoom * FocusZoomVal + bump, MinRenderedScale, MaxRenderedScale) --// the zooms multiply but the bump adds on top so its the same size at any zoom

	if Scale then
		Scale.Scale = totalScale
	end

	local parentAbsSize = MainUI.AbsoluteSize
	local sizeUdim = CameraRoot.Size
	local baseSizePxX = sizeUdim.X.Scale * parentAbsSize.X + sizeUdim.X.Offset --// udim2 to pixels by hand, AbsoluteSize already has the uiscale baked in and would count the zoom twice
	local baseSizePxY = sizeUdim.Y.Scale * parentAbsSize.Y + sizeUdim.Y.Offset

	local targetPxX = FocusAnchor.X.Scale * parentAbsSize.X + FocusAnchor.X.Offset --// where the focus should land on screen in pixels
	local targetPxY = FocusAnchor.Y.Scale * parentAbsSize.Y + FocusAnchor.Y.Offset

	local posPxX = targetPxX - (LocalX * totalScale * baseSizePxX) + OffsetX --// fraction times the scaled size is how far into the root the focus point is, subtract it so that point ends up on the anchor
	local posPxY = targetPxY - (LocalY * totalScale * baseSizePxY) + OffsetY

	CameraRoot.Position = UDim2.fromOffset(posPxX, posPxY) --// offset only cus everything above is already pixels
end

CameraHandle.Reset = function()
	Events = {}
	EventStep = 1
	HasFocused = false --// so the next song snaps to its first focus again

	LocalX, LocalY = 0.5, 0.5
	LocalXAnim, LocalYAnim = nil, nil
	OffsetX, OffsetY = FocusAnchor.X.Offset, FocusAnchor.Y.Offset
	OffsetXAnim, OffsetYAnim = nil, nil

	BaseZoom = 1
	BaseZoomAnim = nil
	FocusZoomVal = 1
	FocusZoomAnim = nil

	LastBeatIndex = -1
	BumpStartTimeMS = -1e9
	LastKnownSongTimeMS = 0

	BopIntensity = 1
	BopRate = BaseBumpEvery

	if CameraRoot then
		CameraRoot.Position = BasePosition --// back to where it started
	end
	if Scale then
		Scale.Scale = 1
	end
end

return CameraHandle
