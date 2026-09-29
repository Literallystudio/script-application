--// 500 comments

--// services

local replicated_storage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local tween_service = game:GetService("TweenService") --// only used for GetValue, the actual tweening is done by hand below

--// modules

local config = require(replicated_storage:WaitForChild("ClientModules"):WaitForChild("Config")) --// every tweakable number lives in here so i dont have to touch this file to tune the camera

--// types

type Ease = {Style: Enum.EasingStyle, Direction: Enum.EasingDirection}

--// ui refs

local main_ui = players.LocalPlayer.PlayerGui:WaitForChild("MainUI") --// waitforchild cus the gui can load after this module gets required
local camera_root = main_ui:WaitForChild("CameraRoot") --// frame holding the whole playfield, moving and scaling this is the "camera"
local focus_points = camera_root:WaitForChild("FocusPoints") --// markers inside the root so they move around with it
local scale = camera_root:FindFirstChildOfClass("UIScale") --// zoom is a uiscale so every child scales with it for free

if scale == nil then
	scale = Instance.new("UIScale") --// made here when the ui doesnt have one, so nothing below needs a nil check
	scale.Parent = camera_root
end

local focus_targets = { --// char from the event to its marker, 0 = player, 1 = opponent, 2 = center
	[0] = focus_points:FindFirstChild("PlayerFocus"),
	[1] = focus_points:FindFirstChild("OpponentFocus"),
	[2] = focus_points:FindFirstChild("CenterFocus"),
}

local focus_anchor = config.CameraFocusAnchor or UDim2.fromScale(0.5, 0.5) --// spot on screen the focused marker gets pulled to, center by default
local base_position = camera_root.Position --// remembered so Reset can put the root back where it started

local camera_handle = {}

--// easing

local ease_styles = { --// chart events name their eases as strings so this turns them into enums
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

local directions = { --// order matters, inout has to be checked first cus it also ends with "out"
	{"inout", Enum.EasingDirection.InOut},
	{"in", Enum.EasingDirection.In},
	{"out", Enum.EasingDirection.Out},
}

local function parse_ease(ease_name: string?): Ease
	local key = (ease_name or ""):lower() --// so QuadOut and quadout both work
	local direction = Enum.EasingDirection.InOut
	for _, entry in directions do
		local suffix = entry[1]
		if key:sub(-#suffix) == suffix then
			direction = entry[2]
			key = key:sub(1, -#suffix - 1) --// chop the direction off the end so only the style name is left
			break
		end
	end
	return { Style = ease_styles[key] or Enum.EasingStyle.Quad, Direction = direction } --// a typo in a chart shouldnt error, just fall back to quad
end

--// tracks, a value that can snap or animate. done by hand instead of tweenservice cus it has to follow the song clock (not real time) or pausing desyncs it

local track = {}
track.__index = track

local function new_track(start)
	return setmetatable({ value = start, anim = nil }, track)
end

function track.snap(self, target)
	self.value, self.anim = target, nil --// clears the anim too or it would drag the value away from the snap
end

function track.animate(self, target, now_ms: number, seconds: number, ease: Ease)
	self.anim = {
		from = self.value, --// starts from wherever it is right now so cutting a pan off mid way doesnt jump
		to = target,
		start_ms = now_ms,
		duration_ms = seconds * 1000, --// song time is in ms
		ease = ease,
	}
end

function track.step(self, now_ms: number)
	local anim = self.anim
	if anim == nil then return end --// nothing running so the value just stays
	local elapsed = now_ms - anim.start_ms
	if elapsed >= anim.duration_ms then
		self.value, self.anim = anim.to, nil --// done, land exactly on the target and clear the anim
	else
		local alpha = math.clamp(elapsed / anim.duration_ms, 0, 1) --// clamp for when song time jumps back a little
		local eased = tween_service:GetValue(alpha, anim.ease.Style, anim.ease.Direction) --// just runs the curve, no tween object gets made
		self.value = anim.from + (anim.to - anim.from) * eased --// plain lerp, works on numbers and vector2s the same way
	end
end

--// state

local start_values = { --// what every track starts at and goes back to on Reset
	focus_point = Vector2.new(0.5, 0.5), --// which spot of the root (0 to 1) sits under the anchor, middle to start
	focus_offset = Vector2.new(focus_anchor.X.Offset, focus_anchor.Y.Offset), --// pixel nudge on top of the focus, comes from x and y in the event
	base_zoom = 1, --// zoom from ZoomCamera events
	focus_zoom = 1, --// separate zoom from focusing, multiplied with base_zoom later so they dont fight over one number
}

local tracks = {}
for name, value in start_values do tracks[name] = new_track(value) end --// one track per value so Update and Reset can just loop them

local has_focused = false --// first focus snaps instead of panning or the camera would slide in from the middle at song start

local events, event_step = {}, 1 --// event_step is the next event that hasnt run yet
local song_time_ms = 0 --// saved every Update so the actions below know what time to start their anims at

local ms_per_beat = 0
local last_beat_index = -1 --// last beat already handled so a bump only starts once per beat
local bump_start_ms = -1e9 --// way in the past so theres no bump before the first beat

local base_bump_amount = config.CameraBeatBumpAmount or 0.015
local base_bump_every = math.max(config.CameraBeatBumpEvery or 1, 1) --// min 1 or the modulo in evaluate_bump would divide by 0
local bop_intensity = 1 --// multiplier on the bump, events change it
local bop_rate = base_bump_every --// bump every x beats, also event controlled

local pan_speed_multiplier = 1 --// pan duration gets divided by this so bigger means faster pans
local min_scale, max_scale = 0, math.huge --// no clamp until SetScaleClamp gets called

--// beat bump

local function set_bpm(bpm)
	if bpm == nil or bpm <= 0 then bpm = config.DefaultBPM or 100 end --// bad or missing bpm falls back to the config one
	ms_per_beat = 60000 / bpm --// 60000 ms in a minute
	last_beat_index = -1 --// old beat index means nothing at the new bpm
	bump_start_ms = -1e9
end

set_bpm(config.DefaultBPM)

local function evaluate_bump(time_ms)
	local beat_index = math.floor(time_ms / ms_per_beat) --// which beat we are on right now
	if beat_index ~= last_beat_index then --// only runs on the frame the beat changes
		last_beat_index = beat_index
		if beat_index % bop_rate == 0 then bump_start_ms = beat_index * ms_per_beat end --// exact beat time instead of now so one laggy frame doesnt shift the bump, modulo skips beats when the rate is over 1
	end
	local elapsed = time_ms - bump_start_ms
	if elapsed < 0 or elapsed >= ms_per_beat then return 0 end --// a bump only lasts one beat
	local decay = 1 - tween_service:GetValue(elapsed / ms_per_beat, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) --// flipped so it starts full and eases down to 0
	return base_bump_amount * bop_intensity * decay
end

--// ui math

local function get_local_fraction(target)
	local root_size = camera_root.AbsoluteSize
	if root_size.X <= 0 or root_size.Y <= 0 then return Vector2.new(0.5, 0.5) end --// ui hasnt laid out yet so dividing would give inf, just say center
	local target_center = target.AbsolutePosition + target.AbsoluteSize * 0.5 --// absolute space so it doesnt matter how deep the marker is parented
	return (target_center - camera_root.AbsolutePosition) / root_size --// 0 to 1 across the root instead of pixels, stays valid at any zoom
end

--// udim2 to pixels by hand, the root's AbsoluteSize already has the uiscale baked in and would count the zoom twice
local function to_pixels(udim, parent_size)
	return Vector2.new(udim.X.Scale * parent_size.X + udim.X.Offset, udim.Y.Scale * parent_size.Y + udim.Y.Offset)
end

--// camera actions

local function zoom_camera(v)
	if type(v) ~= "table" then return end --// bad chart data (like a plain number) just gets ignored
	local duration = v.duration or 0
	if duration <= 0 then
		tracks.base_zoom:snap(v.zoom or 1)
	else
		tracks.base_zoom:animate(v.zoom or 1, song_time_ms, duration, parse_ease(v.ease))
	end
end

local function set_camera_bop(v)
	if type(v) ~= "table" then return end
	if v.intensity ~= nil then bop_intensity = v.intensity end --// only touch what the event actually sent
	if v.rate ~= nil then bop_rate = math.max(v.rate, 1) end
end

--// seconds until the next focus event, nil when there isnt one
local function seconds_to_next_focus(step)
	for i = step + 1, #events do --// look ahead for focus events only, other types dont matter here
		if events[i].e == "FocusCamera" then return (events[i].t - events[step].t) / 1000 end --// ms to seconds
	end
	return nil
end

local function focus_camera(value, step)
	local v = if type(value) == "table" then value elseif type(value) == "number" then { char = value } else {} --// a number is the shorthand event (just the char), junk falls back to defaults
	local char = v.char or 0 --// no char means player
	local target = focus_targets[char]
	if target == nil then warn(string.format("CameraHandle: no FocusPoints marker for char=%s - ignoring FocusCamera.", tostring(char))); return end --// warn not error, one bad event shouldnt kill the song

	local goals = { --// where every focus track is heading
		focus_point = get_local_fraction(target),
		focus_offset = Vector2.new(focus_anchor.X.Offset + (v.x or 0), focus_anchor.Y.Offset + (v.y or 0)), --// x and y in the event push the camera off the marker a bit
		focus_zoom = config.CameraFocusZoom or 1,
	}

	local raw_duration = v.duration or config.CameraDefaultPanDuration or 4 --// the event can override the default pan time
	local snap = not has_focused or raw_duration <= 0 --// first focus and zero length pans jump straight there
	has_focused = true

	local duration = raw_duration / pan_speed_multiplier
	local max_gap = seconds_to_next_focus(step)
	if max_gap ~= nil then duration = math.min(duration, math.max(max_gap * 0.9, 0.05)) end --// 90% of the gap to the next focus so the pan ends before the next one starts, 0.05 floor so it never hits 0

	local ease = parse_ease(v.ease or config.CameraDefaultPanEase)
	for name, goal in goals do
		if snap then tracks[name]:snap(goal) else tracks[name]:animate(goal, song_time_ms, duration, ease) end --// all of them share the duration and ease so the camera moves as one
	end
end

local event_handlers = { --// every handler gets the event value and its index in the list
	FocusCamera = focus_camera,
	ZoomCamera = zoom_camera,
	SetCameraBop = set_camera_bop,
}

--// public api

camera_handle.LoadEvents = function(new_events)
	events = new_events or {} --// expects them sorted by time, Update reads them in order
	event_step = 1
end

camera_handle.SetPanSpeedMultiplier = function(multiplier)
	pan_speed_multiplier = math.max(multiplier, 0.01) --// floor so it never divides by 0
end

camera_handle.SetScaleClamp = function(min_value, max_value)
	min_scale = math.min(min_value, max_value) --// min and max so passing them swapped doesnt break the clamp
	max_scale = math.max(min_value, max_value)
end

camera_handle.SetBPM = set_bpm

camera_handle.Update = function(time_ms)
	song_time_ms = time_ms --// set first, the actions below read it for their start time

	local event = events[event_step]
	while event and time_ms >= event.t do --// while and not if cus more than one event can land on the same frame
		local handler = event_handlers[event.e]
		if handler then
			handler(event.v, event_step)
		else
			warn(string.format("CameraHandle: unknown event type '%s' at t=%s", tostring(event.e), tostring(event.t))) --// misspelled event names show up in output instead of silently doing nothing
		end
		event_step += 1 --// moving the step forward is what stops an event from running twice
		event = events[event_step]
	end

	for _, value_track in tracks do value_track:step(time_ms) end --// every track moves itself and clears its anim once its done

	local total_scale = math.clamp(tracks.base_zoom.value * tracks.focus_zoom.value + evaluate_bump(time_ms), min_scale, max_scale) --// the zooms multiply but the bump adds on top so its the same size at any zoom
	scale.Scale = total_scale

	local parent_size = main_ui.AbsoluteSize
	local anchor_px = to_pixels(focus_anchor, parent_size) --// where the focus should land on screen in pixels
	local base_size_px = to_pixels(camera_root.Size, parent_size)
	local position = anchor_px - tracks.focus_point.value * total_scale * base_size_px + tracks.focus_offset.value --// fraction times the scaled size is how far into the root the focus point is, subtract it so that point ends up on the anchor
	camera_root.Position = UDim2.fromOffset(position.X, position.Y) --// offset only cus everything above is already pixels
end

camera_handle.Reset = function()
	events, event_step = {}, 1
	has_focused = false --// so the next song snaps to its first focus again
	for name, value in start_values do tracks[name]:snap(value) end

	last_beat_index, bump_start_ms = -1, -1e9
	song_time_ms = 0
	bop_intensity, bop_rate = 1, base_bump_every

	camera_root.Position = base_position --// back to where it started
	scale.Scale = 1
end

return camera_handle
