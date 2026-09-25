--!strict
--!native
--!optimize 2

--[[
	ArrowHandle (client)

  dear whoever reads this
    im so sorry

	main arrow code

	how this file is laid out:
		-types and requires (so the analyzer stops yelling at me)
		- state (yes there is a lot, no im not proud)
		- small systems (characters, hold covers, splashes, judgements)
		- the big heartbeat loop
		- song lifecycle (LoadSong / EndSong / teardown)
		- public api (the stuff other scripts are allowed to touch)

	if something breaks, it was probably the timing code. it is always the timing code.

if someone exploits this, i dont care
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- types
-- most of my modules are untyped so i describe what i expect them to return and cast.
-- if a module changes shape this is where the red squiggles show up

export type Side = "Player" | "Opponent"
export type JudgementName = "Sick" | "Good" | "Ok" | "Bad" | "Miss"

type AnimTable = { [string]: { any } }

type SideTransform = { Size: UDim2?, Pos: UDim2? }
type FramesData = {
	_Data: { PlayerSide: SideTransform?, OpponentSide: SideTransform? }?,
}

type CharacterDef = { Frames: FramesData, Anims: AnimTable, Prefix: string }
type EffectData = { Frames: any, Anims: AnimTable }

type AnimPlayer = {
	Frames: any,
	Anims: AnimTable,
	ImageLabel: ImageLabel,
	Play: (self: AnimPlayer, name: string, fps: number, loop: boolean) -> (),
	Stop: (self: AnimPlayer) -> (),
}
type AnimPlayerClass = {
	new: (imageLabel: ImageLabel, frames: any, anims: AnimTable) -> AnimPlayer,
}

type HoldPiece = { body: number, endCap: number }

type ConfigModule = {
	LaneMap: { [number]: any },
	TravelTime: number,
	AudioOffsetMS: number,
	SickWindow: number,
	GoodWindow: number,
	OkWindow: number,
	BadWindow: number,
	DefaultScrollSpeed: number,
	DefaultBPM: number,
	DefaultGhostTapProtection: boolean,
	DefaultBotplayEnabled: boolean,
	JudgementAccuracyWeight: { [string]: number },
	MaxScore: number,
	MissScorePenalty: number,
	HoldAssetImage: string,
	HoldPieceWidth: number,
	HoldPieceHeight: number,
	HoldPieceX: { [string]: HoldPiece },
	HoldBodyTilePx: number,
	HoldEndCapHeightPx: number,
	HoldCoverColors: { [string]: string }?,
	HoldCoverFrameData: { [string]: EffectData }?,
	HoldCoverLoopFPS: number?,
	SickSplashFrameData: { [string]: EffectData }?,
	SickSplashFPS: number?,
}

type SongCatalogModule = {
	FindSongModule: (songName: string) -> ModuleScript?,
	GetSeparateChartPrefix: (songName: string, difficulty: string) -> string?,
	GetSongAudio: (songName: string, difficulty: string, songModule: ModuleScript) -> { Sound },
}

type CameraHandleModule = {
	Reset: () -> (),
	LoadEvents: (events: any) -> (),
	SetBPM: (bpm: number) -> (),
	Update: (songTimeMS: number) -> (),
}

-- t = time in ms, l = lane index, d = hold duration in ms, k = optional key event payload
type ChartNote = { t: number, l: number, d: number?, k: any? }
type ScrollSpeedEntry = { ScrollSpeed: number?, BPM: number? }
type SongModule = {
	Charts: { [string]: { ChartNote } }?,
	ScrollSpeed: (number | { [string]: number | ScrollSpeedEntry })?,
}

-- one live arrow on screen. hold notes just get the extra fields filled in
type Note = {
	HitTime: number,
	Duration: number?,
	Instance: ImageLabel,
	Lane: string,
	Side: Side,
	StartPos: UDim2,
	StartY: number,
	SpawnSongTimeMS: number,
	VisualTravelTime: number,
	Judged: boolean,
	IsHold: boolean,
	HoldActive: boolean,
	HoldDurationMS: number?,
	HoldEndSongTimeMS: number?,
	HoldTrail: Frame?,
}

type SideStats = {
	Counts: { [JudgementName]: number },
	Score: number,
	AccuracyWeightSum: number,
	AccuracyNoteCount: number,
	TotalNotes: number,
}

type CharacterSlot = {
	Character: ImageLabel,
	Animator: AnimPlayer,
	Prefix: string,
	IdleToken: number,
}

type Watcher = { Value: StringValue?, Conn: RBXScriptConnection? }

type SideUI = {
	Track: GuiObject,
	Receptors: GuiObject,
	Judgements: GuiObject,
	HoldTargets: GuiObject,
}

-- requires and ui lookups
-- everything goes through WaitForChild + IsA now. before, one typo in the hierarchy
-- meant "attempt to index nil" forty lines later. never again

local function requireChild(parent: Instance, name: string): any
	local child = parent:WaitForChild(name)
	assert(child:IsA("ModuleScript"), name .. " is not a ModuleScript (what did i do this time)")
	return require(child) :: any -- always returns the correct module probably maybe idk
end

local function getGui(parent: Instance, name: string): GuiObject
	local child = parent:WaitForChild(name)
	assert(child:IsA("GuiObject"), parent:GetFullName() .. "." .. name .. " should be a GuiObject")
	return child
end

local function getImage(parent: Instance, name: string): ImageLabel
	local child = parent:WaitForChild(name)
	assert(child:IsA("ImageLabel"), parent:GetFullName() .. "." .. name .. " should be an ImageLabel")
	return child
end

local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")
local Config = requireChild(ClientModules, "Config") :: ConfigModule
local SongCatalog = require("../SongCatalog") :: SongCatalogModule
local CameraHandle = require("../CameraHandle") :: CameraHandleModule

local CharModules = ClientModules:WaitForChild("CharModules")
local AnimPlayerClass = requireChild(CharModules, "AnimPlayer") :: AnimPlayerClass

local LocalPlayer = Players.LocalPlayer :: Player
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local MainUI = PlayerGui:WaitForChild("MainUI")
local CameraRoot = MainUI:WaitForChild("CameraRoot")
local CharactersFolder = CameraRoot:WaitForChild("Characters")

local function buildSideUI(root: GuiObject): SideUI
	local track = getGui(root, "TrackMain")
	return {
		Track = track,
		Receptors = getGui(root, "PlayerArrows"), -- yes the opponents are also called PlayerArrows. dont ask
		Judgements = getGui(root, "Judgements"),
		HoldTargets = getGui(track, "HoldTargets"),
	}
end

local SideUIs: { [Side]: SideUI } = {
	Player = buildSideUI(getGui(MainUI, "Player")),
	Opponent = buildSideUI(getGui(MainUI, "Opponent")),
}

-- constants

local SIDES: { Side } = { "Player", "Opponent" }
local JUDGEMENT_NAMES: { JudgementName } = { "Sick", "Good", "Ok", "Bad", "Miss" }
local LABEL_NAMES = { "Sick", "Good", "Ok", "Bad", "Miss", "Score", "Accuracy" }

local DEFAULT_CHARACTER = "Boy"
local ANIM_FPS = 24
local IDLE_DELAY = 0.7 -- how long before the dude gives up and goes back to idling
local HEY_FROZEN_SECONDS = 0.9
local DEFAULT_TARGET_Y = 0.124 -- magic number from ages ago, kept as a fallback because im scared to delete it
local BOT_RELEASE_DELAY = 0.1
local MIN_SCROLL_SPEED = 0.1 -- 0 would divide by zero and i would cry
local CHARACTER_STRING_TIMEOUT = 5

local LaneMap = Config.LaneMap
local TravelTime = Config.TravelTime
local AudioOffsetMS = Config.AudioOffsetMS
local SickWindow = Config.SickWindow
local GoodWindow = Config.GoodWindow
local OkWindow = Config.OkWindow
local BadWindow = Config.BadWindow
local JudgementAccuracyWeight = Config.JudgementAccuracyWeight

local NoteAnimSuffix: { [string]: string } = {
	UP = "NOTE UP",
	DOWN = "NOTE DOWN",
	LEFT = "NOTE LEFT",
	RIGHT = "NOTE RIGHT",
}

local NoteMissAnimSuffix: { [string]: string } = {
	UP = "NOTE UP MISS",
	DOWN = "NOTE DOWN MISS",
	LEFT = "NOTE LEFT MISS",
	RIGHT = "NOTE RIGHT MISS",
}

-- asset ids, copy pasted from the toolbox at 3am. if an arrow looks wrong check here first
local PressedArrowImages: { [string]: string } = {
	LEFT = "rbxassetid://102149802750264",
	UP = "rbxassetid://114660383196726",
	DOWN = "rbxassetid://135674495554200",
	RIGHT = "rbxassetid://99497856983095",
}

local ReleasedArrowImages: { [string]: string } = {
	LEFT = "rbxassetid://90658588929930",
	UP = "rbxassetid://130339318866047",
	DOWN = "rbxassetid://136194564054245",
	RIGHT = "rbxassetid://71125454966573",
}

-- state
-- module level mutable state. not pretty, but its a client singleton so
-- im calling it "architecture"

local ArrowHandle = {}

local ClickCount = 0
local ScrollSpeed = Config.DefaultScrollSpeed
local BotplayEnabled = Config.DefaultBotplayEnabled
local GhostTapProtectionEnabled = Config.DefaultGhostTapProtection
local CurrentWinCondition = "Score"
local LastMatchWinner: string? = nil
local LocalSide: Side = "Player"

local MatchActive = false
local SongSelectionActive = false

local SongEndCallbacks: { () -> () } = {}

local ActiveNotes: { [Side]: { [string]: { Note } } } = { Player = {}, Opponent = {} }
local HeldKeys: { [Side]: { [string]: boolean } } = { Player = {}, Opponent = {} }

-- audio and timing
local MainAudioObject: Sound? = nil
local ActiveSongAudios: { Sound } = {}
local AudioStarted = false
local SongLeadInStartClock: number? = nil
local SongLeadInDelayMS = 0
local SongGeneration = 0 -- bumped whenever a song dies so stale callbacks know to shut up

-- the chart were currently playing
local ActiveChart: { ChartNote } = {}
local ChartStep = 1
local ChartKeyEvent: BindableEvent? = nil

local function NewStats(): SideStats
	return {
		Counts = { Sick = 0, Good = 0, Ok = 0, Bad = 0, Miss = 0 },
		Score = 0,
		AccuracyWeightSum = 0,
		AccuracyNoteCount = 0,
		TotalNotes = 0,
	}
end

local Stats: { [Side]: SideStats } = { Player = NewStats(), Opponent = NewStats() }

local function OppositeSide(side: Side): Side
	if side == "Player" then
		return "Opponent"
	end
	return "Player"
end

local function GetSide(lane: number): Side
	if lane >= 4 then
		return "Opponent"
	end
	return "Player"
end

local function IsCharacterLocked(): boolean
	return MatchActive or SongSelectionActive
end

local function IsHoldNote(note: Note): boolean
	return note.Duration ~= nil and note.Duration > 0
end

-- lane lookups (cached)
-- calling FindFirstChild every frame for every note was... not great. now we remember stuff

local ReceptorCache: { [Side]: { [string]: ImageLabel } } = { Player = {}, Opponent = {} }
local HoldTargetCache: { [Side]: { [string]: GuiObject } } = { Player = {}, Opponent = {} }

local function GetReceptor(side: Side, lane: string): ImageLabel?
	local cache = ReceptorCache[side]
	local cached = cache[lane]
	if cached and cached.Parent then
		return cached
	end
	local found = SideUIs[side].Receptors:FindFirstChild(lane)
	if found and found:IsA("ImageLabel") then
		cache[lane] = found
		return found
	end
	return nil
end

local function GetHoldTarget(side: Side, lane: string): GuiObject?
	local cache = HoldTargetCache[side]
	local cached = cache[lane]
	if cached and cached.Parent then
		return cached
	end
	local found = SideUIs[side].HoldTargets:FindFirstChild(lane)
	if found and found:IsA("GuiObject") then
		cache[lane] = found
		return found
	end
	return nil
end

local function GetTargetY(side: Side, lane: string): number
	local target = GetHoldTarget(side, lane)
	if target then
		return target.Position.Y.Scale
	end
	return DEFAULT_TARGET_Y
end

-- timing

local function GetSongTimeMS(): number
	if not MainAudioObject then
		return 0
	end
	if not AudioStarted then
		-- audio hasnt started yet so we fake the clock during the lead in
		local startClock = SongLeadInStartClock
		if not startClock then
			return -SongLeadInDelayMS
		end
		return -SongLeadInDelayMS + (os.clock() - startClock) * 1000
	end
	return (MainAudioObject.TimePosition * 1000) + AudioOffsetMS
end

local function GetVisualTravelTime(): number
	return TravelTime / ScrollSpeed
end

-- judgements and score

local JudgementLabels: { [Side]: { [string]: TextLabel } } = { Player = {}, Opponent = {} }

for _, side in ipairs(SIDES) do
	for _, name in ipairs(LABEL_NAMES) do
		local label = SideUIs[side].Judgements:FindFirstChild(name)
		if label and label:IsA("TextLabel") then
			JudgementLabels[side][name] = label
		else
			warn("Judgements label missing: " .. side .. "." .. name .. " (score ui will be a bit lonely)")
		end
	end
end

local function GetAccuracy(side: Side): number
	local stats = Stats[side]
	if stats.AccuracyNoteCount == 0 then
		return 100
	end
	return (stats.AccuracyWeightSum / stats.AccuracyNoteCount) * 100
end

local function ComputeScore(side: Side): number
	local stats = Stats[side]
	if stats.TotalNotes <= 0 then
		return 0
	end
	local raw = math.floor((stats.AccuracyWeightSum / stats.TotalNotes) * Config.MaxScore + 0.5)
	raw -= stats.Counts.Miss * Config.MissScorePenalty
	return math.max(0, raw)
end

local function UpdateScoreDisplay(side: Side)
	local labels = JudgementLabels[side]
	local scoreLabel = labels.Score
	if scoreLabel then
		scoreLabel.Text = "Score: " .. tostring(Stats[side].Score)
	end
	local accuracyLabel = labels.Accuracy
	if accuracyLabel then
		accuracyLabel.Text = string.format("Accuracy: %.2f%%", GetAccuracy(side))
	end
end

local function ApplyJudgement(side: Side, judgement: JudgementName)
	local stats = Stats[side]
	stats.Counts[judgement] += 1
	local label = JudgementLabels[side][judgement]
	if label then
		label.Text = judgement .. ": " .. tostring(stats.Counts[judgement])
	end
	stats.AccuracyNoteCount += 1
	stats.AccuracyWeightSum += JudgementAccuracyWeight[judgement] or 0
	stats.Score = ComputeScore(side)
	UpdateScoreDisplay(side)
end

local function ResetStats()
	for _, side in ipairs(SIDES) do
		local stats = Stats[side]
		for _, name in ipairs(JUDGEMENT_NAMES) do
			stats.Counts[name] = 0
			local label = JudgementLabels[side][name]
			if label then
				label.Text = name .. ": 0"
			end
		end
		stats.Score = 0
		stats.AccuracyWeightSum = 0
		stats.AccuracyNoteCount = 0
		stats.TotalNotes = 0
		UpdateScoreDisplay(side)
	end
end

local function ComputeMatchWinner()
	local playerValue: number
	local opponentValue: number
	local higherWins = true
	if CurrentWinCondition == "Score" then
		playerValue = Stats.Player.Score
		opponentValue = Stats.Opponent.Score
	elseif CurrentWinCondition == "Accuracy" then
		playerValue = GetAccuracy("Player")
		opponentValue = GetAccuracy("Opponent")
	else
		-- anything else means fewest misses wins
		playerValue = Stats.Player.Counts.Miss
		opponentValue = Stats.Opponent.Counts.Miss
		higherWins = false
	end

	if playerValue == opponentValue then
		LastMatchWinner = "Draw"
	elseif (playerValue > opponentValue) == higherWins then
		LastMatchWinner = "Player"
	else
		LastMatchWinner = "Opponent"
	end
end

-- characters
-- two dancers, one code path. it used to be two copies of everything and i kept
-- fixing a bug in one and forgetting the other. classic

local function loadCharacterDef(folderName: string): CharacterDef
	local folder = CharModules:WaitForChild(folderName)
	return {
		Frames = requireChild(folder, "Frames"),
		Anims = requireChild(folder, "Anims"),
		Prefix = folderName,
	}
end

local CharacterDefs: { [string]: CharacterDef } = {
	Boy = loadCharacterDef("Boy"),
	BoyGirl = loadCharacterDef("BoyGirl"),
}

local function newSlot(characterName: string): CharacterSlot
	local character = getImage(CharactersFolder, characterName)
	local def = CharacterDefs[DEFAULT_CHARACTER]
	return {
		Character = character,
		Animator = AnimPlayerClass.new(character, def.Frames, def.Anims),
		Prefix = def.Prefix,
		IdleToken = 0,
	}
end

local Slots: { [Side]: CharacterSlot } = {
	Player = newSlot("Boy"),
	Opponent = newSlot("BoyOP"),
}

local function IsHoldingAnyLane(side: Side): boolean
	for _, list in pairs(ActiveNotes[side]) do
		for _, note in ipairs(list) do
			if note.HoldActive then
				return true
			end
		end
	end
	return false
end

local function PlayIdle(side: Side)
	local slot = Slots[side]
	slot.Animator:Play(slot.Prefix .. " idle dance", ANIM_FPS, true)
end

local function PlayNoteAnim(side: Side, lane: string)
	local suffix = NoteAnimSuffix[lane]
	if suffix then
		local slot = Slots[side]
		slot.Animator:Play(slot.Prefix .. " " .. suffix, ANIM_FPS, false)
	end
end

local function PlayMissAnim(side: Side, lane: string)
	local suffix = NoteMissAnimSuffix[lane]
	if suffix then
		local slot = Slots[side]
		slot.Animator:Play(slot.Prefix .. " " .. suffix, ANIM_FPS, false)
	end
end

-- goes back to idle after a delay unless something newer bumped the token first.
-- newer anim = old timer is stale = it quietly does nothing
local function ScheduleIdle(side: Side, delaySeconds: number?)
	local slot = Slots[side]
	slot.IdleToken += 1
	local myToken = slot.IdleToken
	task.delay(delaySeconds or IDLE_DELAY, function()
		if myToken ~= slot.IdleToken then
			return
		end
		if not IsHoldingAnyLane(side) then
			PlayIdle(side)
		end
	end)
end

local function PlayTimedAnim(side: Side, animName: string, seconds: number)
	Slots[side].Animator:Play(animName, ANIM_FPS, false)
	ScheduleIdle(side, seconds)
end

local function ApplySideTransform(imageLabel: ImageLabel, def: CharacterDef, side: Side)
	local data = def.Frames._Data
	if not data then
		return
	end
	local sideData = if side == "Opponent" then data.OpponentSide else data.PlayerSide
	if not sideData then
		return
	end
	if sideData.Size then
		imageLabel.Size = sideData.Size
	end
	if sideData.Pos then
		imageLabel.Position = sideData.Pos
	end
end

local function ApplyCharacter(side: Side, characterName: string)
	-- swapping skins mid song looks cursed so we just refuse
	if IsCharacterLocked() then
		return
	end
	local def = CharacterDefs[characterName] or CharacterDefs[DEFAULT_CHARACTER]
	local slot = Slots[side]
	slot.Animator.Frames = def.Frames
	slot.Animator.Anims = def.Anims
	slot.Prefix = def.Prefix
	ApplySideTransform(slot.Character, def, side)
	if not IsHoldingAnyLane(side) then
		PlayIdle(side)
	end
end

-- watchers listen to the charString values so skins update live (outside of matches)
local LocalWatcher: Watcher = { Value = nil, Conn = nil }
local OpponentWatcher: Watcher = { Value = nil, Conn = nil }
local OpponentRequestId = 0 -- so a slow WaitForChild cant land after a newer request

local function DisconnectWatcher(watcher: Watcher)
	if watcher.Conn then
		watcher.Conn:Disconnect()
		watcher.Conn = nil
	end
end

local function ConnectWatcher(watcher: Watcher, getSide: () -> Side)
	local value = watcher.Value
	if watcher.Conn or not value then
		return
	end
	watcher.Conn = value:GetPropertyChangedSignal("Value"):Connect(function()
		ApplyCharacter(getSide(), value.Value)
	end)
end

local function GetLocalDisplaySide(): Side
	return LocalSide
end

local function GetOpponentDisplaySide(): Side
	return OppositeSide(LocalSide)
end

local function RefreshWatcherState()
	if IsCharacterLocked() then
		DisconnectWatcher(LocalWatcher)
		DisconnectWatcher(OpponentWatcher)
		return
	end

	local botSide = OppositeSide(LocalSide)
	if OpponentWatcher.Value then
		ApplyCharacter(botSide, OpponentWatcher.Value.Value)
	else
		ApplyCharacter(botSide, DEFAULT_CHARACTER)
	end
	if LocalWatcher.Value then
		ApplyCharacter(LocalSide, LocalWatcher.Value.Value)
	end

	ConnectWatcher(LocalWatcher, GetLocalDisplaySide)
	ConnectWatcher(OpponentWatcher, GetOpponentDisplaySide)
end

local function ResetOpponentCharacter()
	OpponentRequestId += 1
	DisconnectWatcher(OpponentWatcher)
	OpponentWatcher.Value = nil
	ApplyCharacter(OppositeSide(LocalSide), DEFAULT_CHARACTER)
end

-- hold covers and sick splashes
-- the sparkly overlays on the receptors. both lazily make an AnimPlayer per lane
-- the first time theyre needed

local HoldCoverLoopFPS = Config.HoldCoverLoopFPS or ANIM_FPS
local SickSplashFPS = Config.SickSplashFPS or ANIM_FPS

local HoldCoverPlayers: { [Side]: { [string]: AnimPlayer } } = { Player = {}, Opponent = {} }
local SickSplashPlayers: { [Side]: { [string]: AnimPlayer } } = { Player = {}, Opponent = {} }
local SickSplashTokens: { [Side]: { [string]: number } } = { Player = {}, Opponent = {} }

local function GetLaneEffectData(lane: string, dataSet: { [string]: EffectData }?, label: string): EffectData?
	local colors = Config.HoldCoverColors
	local color = if colors then colors[lane] else nil
	local data = if color and dataSet then dataSet[color] else nil
	if not data then
		warn(label .. ": no frame data for lane " .. lane .. " (color " .. tostring(color) .. ")")
	end
	return data
end

local function GetHoldCoverPlayer(side: Side, lane: string): AnimPlayer?
	local existing = HoldCoverPlayers[side][lane]
	if existing then
		return existing
	end
	local target = GetHoldTarget(side, lane)
	if not target then
		return nil
	end
	local imageLabel = target:FindFirstChild("ImageLabel")
	if not imageLabel or not imageLabel:IsA("ImageLabel") then
		warn("HoldCover: no ImageLabel under HoldTargets." .. lane .. " (" .. side .. ")")
		return nil
	end
	local data = GetLaneEffectData(lane, Config.HoldCoverFrameData, "HoldCover")
	if not data then
		return nil
	end
	local player = AnimPlayerClass.new(imageLabel, data.Frames, data.Anims)
	imageLabel.Visible = false
	HoldCoverPlayers[side][lane] = player
	return player
end

local function StartHoldCover(side: Side, lane: string)
	local player = GetHoldCoverPlayer(side, lane)
	if not player then
		return
	end
	player.ImageLabel.Visible = true
	player.ImageLabel.ImageTransparency = 0
	player:Play("Loop", HoldCoverLoopFPS, true)
end

local function StopHoldCover(side: Side, lane: string)
	local player = HoldCoverPlayers[side][lane]
	if not player then
		return
	end
	player:Stop()
	player.ImageLabel.Visible = false
end

local function ResetAllHoldCovers()
	for _, side in ipairs(SIDES) do
		for lane in pairs(HoldCoverPlayers[side]) do
			StopHoldCover(side, lane)
		end
	end
end

local function GetSickSplashPlayer(side: Side, lane: string): AnimPlayer?
	local existing = SickSplashPlayers[side][lane]
	if existing then
		return existing
	end
	local target = GetHoldTarget(side, lane)
	if not target then
		return nil
	end
	local baseImageLabel = target:FindFirstChild("ImageLabel")
	if not baseImageLabel or not baseImageLabel:IsA("ImageLabel") then
		warn("SickSplash: no ImageLabel under HoldTargets." .. lane .. " (" .. side .. ")")
		return nil
	end
	local data = GetLaneEffectData(lane, Config.SickSplashFrameData, "SickSplash")
	if not data then
		return nil
	end
	-- clone it so the splash doesnt fight the hold cover over the same label
	local splashImageLabel = baseImageLabel:Clone() :: ImageLabel
	splashImageLabel.Name = "SickSplashImage"
	splashImageLabel.Visible = false
	splashImageLabel.Parent = target
	local player = AnimPlayerClass.new(splashImageLabel, data.Frames, data.Anims)
	SickSplashPlayers[side][lane] = player
	return player
end

local function PlaySickSplash(side: Side, lane: string)
	local player = GetSickSplashPlayer(side, lane)
	if not player then
		return
	end
	local tokens = SickSplashTokens[side]
	tokens[lane] = (tokens[lane] or 0) + 1
	local myToken = tokens[lane]

	player.ImageLabel.Visible = true
	player.ImageLabel.ImageTransparency = 0
	player:Play("Splash", SickSplashFPS, false)

	local frameCount = #(player.Anims.Splash or {})
	task.delay(frameCount / SickSplashFPS, function()
		if tokens[lane] ~= myToken then
			return -- a newer splash took over, it can clean up after itself
		end
		player:Stop()
		player.ImageLabel.Visible = false
	end)
end

local function ResetAllSickSplashes()
	for _, side in ipairs(SIDES) do
		local tokens = SickSplashTokens[side]
		for lane, player in pairs(SickSplashPlayers[side]) do
			tokens[lane] = (tokens[lane] or 0) + 1
			player:Stop()
			player.ImageLabel.Visible = false
		end
	end
end

-- receptor visuals

local function SetReceptorPressed(side: Side, lane: string)
	local receptor = GetReceptor(side, lane)
	if not receptor then
		return
	end
	local image = PressedArrowImages[lane]
	if image then
		receptor.Image = image
	else
		warn("No pressed image found for direction: " .. lane)
	end
end

local function SetReceptorReleased(side: Side, lane: string)
	local receptor = GetReceptor(side, lane)
	if not receptor then
		return
	end
	local image = ReleasedArrowImages[lane]
	if image then
		receptor.Image = image
	else
		warn("No released image found for direction: " .. lane)
	end
	receptor.ImageTransparency = 0
end

-- note geometry and hold trails
-- all the UDim2 maths lives here. if a hold trail looks 2px off, blame this

local function GetTravelRate(note: Note): number
	return (GetTargetY(note.Side, note.Lane) - note.StartY) / note.VisualTravelTime
end

local function GetArrowBottomOffset(note: Note): number
	return note.Instance.AbsoluteSize.Y * (1 - note.Instance.AnchorPoint.Y)
end

local function GetArrowCenterOffsetX(note: Note): number
	return note.Instance.AbsoluteSize.X * (0.5 - note.Instance.AnchorPoint.X)
end

local function CreateHoldTrail(note: Note): Frame
	local pieces = Config.HoldPieceX[note.Lane]
	local trail = Instance.new("Frame")
	trail.Name = "HoldTrail"
	trail.AnchorPoint = Vector2.new(0.5, 0)
	trail.BackgroundTransparency = 1
	trail.BorderSizePixel = 0
	trail.ZIndex = 1
	trail.Position = UDim2.new(
		note.StartPos.X.Scale,
		note.StartPos.X.Offset + GetArrowCenterOffsetX(note),
		note.StartY,
		note.StartPos.Y.Offset + GetArrowBottomOffset(note)
	)
	trail.Size = UDim2.new(note.Instance.Size.X.Scale * 0.5, 0, 0, 0)

	if pieces then
		local body = Instance.new("ImageLabel")
		body.Name = "Body"
		body.BackgroundTransparency = 1
		body.BorderSizePixel = 0
		body.Image = Config.HoldAssetImage
		body.ScaleType = Enum.ScaleType.Tile
		body.TileSize = UDim2.new(1, 0, 0, Config.HoldBodyTilePx)
		body.ImageRectOffset = Vector2.new(pieces.body, 0)
		body.ImageRectSize = Vector2.new(Config.HoldPieceWidth, Config.HoldPieceHeight)
		body.Size = UDim2.fromScale(1, 1)
		body.ZIndex = trail.ZIndex
		body.Parent = trail

		local endCap = Instance.new("ImageLabel")
		endCap.Name = "EndCap"
		endCap.BackgroundTransparency = 1
		endCap.BorderSizePixel = 0
		endCap.Image = Config.HoldAssetImage
		endCap.ScaleType = Enum.ScaleType.Crop
		endCap.ImageRectOffset = Vector2.new(pieces.endCap, 0)
		endCap.ImageRectSize = Vector2.new(Config.HoldPieceWidth, Config.HoldPieceHeight)
		endCap.AnchorPoint = Vector2.new(0.5, 1)
		endCap.Position = UDim2.new(0.5, 0, 1, 0)
		endCap.Size = UDim2.new(1, 0, 0, Config.HoldEndCapHeightPx)
		endCap.ZIndex = trail.ZIndex + 1
		endCap.Parent = trail
	end

	trail.Parent = SideUIs[note.Side].Track
	return trail
end

-- while the note is still flying at the receptor the trail hangs behind it at full length
local function PositionApproachingHoldTrail(note: Note, headY: number)
	local trail = note.HoldTrail
	if not trail then
		return
	end
	local fullLength = math.max(-GetTravelRate(note) * (note.Duration or 0), 0)
	trail.Position = UDim2.new(
		note.StartPos.X.Scale,
		note.StartPos.X.Offset + GetArrowCenterOffsetX(note),
		headY,
		note.StartPos.Y.Offset + GetArrowBottomOffset(note)
	)
	trail.Size = UDim2.new(trail.Size.X.Scale, trail.Size.X.Offset, fullLength, 0)
end

-- once youre holding, the trail gets eaten from the bottom as time runs out
local function UpdateHoldTrail(note: Note, remainingMS: number)
	local trail = note.HoldTrail
	if not trail then
		return
	end
	local length = math.max(-GetTravelRate(note) * remainingMS, 0)
	trail.Position = UDim2.new(
		note.StartPos.X.Scale,
		note.StartPos.X.Offset + GetArrowCenterOffsetX(note),
		GetTargetY(note.Side, note.Lane),
		note.StartPos.Y.Offset + GetArrowBottomOffset(note)
	)
	trail.Size = UDim2.new(trail.Size.X.Scale, trail.Size.X.Offset, length, 0)
end

local function DestroyNote(note: Note)
	if note.HoldTrail then
		note.HoldTrail:Destroy()
		note.HoldTrail = nil
	end
	note.Instance:Destroy()
end

local function RemoveNote(note: Note)
	local list = ActiveNotes[note.Side][note.Lane]
	if list then
		local idx = table.find(list, note)
		if idx then
			table.remove(list, idx)
		end
	end
	DestroyNote(note)
end

local function EndHold(note: Note)
	StopHoldCover(note.Side, note.Lane)
	SetReceptorReleased(note.Side, note.Lane)
	RemoveNote(note)
	ScheduleIdle(note.Side)
end

-- hit judging

local function JudgeAndConsume(note: Note, absOffset: number)
	local side, lane = note.Side, note.Lane

	local judgement: JudgementName
	if absOffset <= SickWindow then
		judgement = "Sick"
	elseif absOffset <= GoodWindow then
		judgement = "Good"
	elseif absOffset <= OkWindow then
		judgement = "Ok"
	else
		judgement = "Bad"
	end

	ApplyJudgement(side, judgement)
	PlayNoteAnim(side, lane)
	if judgement == "Sick" then
		PlaySickSplash(side, lane)
	end

	note.Judged = true
	if IsHoldNote(note) then
		-- the head snaps to the receptor and the note becomes a hold that we babysit in the loop
		local duration = note.Duration or 0
		note.IsHold = true
		note.HoldActive = true
		note.HoldDurationMS = duration
		note.HoldEndSongTimeMS = note.HitTime + duration
		note.Instance.Position = UDim2.new(
			note.StartPos.X.Scale,
			note.StartPos.X.Offset,
			GetTargetY(side, lane),
			note.StartPos.Y.Offset
		)
		UpdateHoldTrail(note, duration)
		StartHoldCover(side, lane)
	else
		RemoveNote(note)
		ScheduleIdle(side)
	end
end

local function RegisterGhostMiss(side: Side, lane: string, noteToRemove: Note?)
	-- with ghost tap protection you get the animation but no punishment. very forgiving of me
	if GhostTapProtectionEnabled then
		PlayNoteAnim(side, lane)
		ScheduleIdle(side)
		return
	end
	ApplyJudgement(side, "Miss")
	PlayMissAnim(side, lane)
	ScheduleIdle(side)
	if noteToRemove then
		RemoveNote(noteToRemove)
	end
end

local function HandlePress(side: Side, lane: string)
	if not MainAudioObject then
		return
	end
	local list = ActiveNotes[side][lane]
	if not list or #list == 0 then
		RegisterGhostMiss(side, lane)
		return
	end

	local now = GetSongTimeMS()

	-- sweep out notes that are already too late (the heartbeat would get them
	-- eventually but we might beat it to it)
	for i = #list, 1, -1 do
		local stale = list[i]
		if not stale.Judged and now - stale.HitTime > BadWindow then
			RemoveNote(stale)
		end
	end

	-- earliest unjudged note in this lane wins
	local closest: Note? = nil
	for _, candidate in ipairs(list) do
		if not candidate.Judged and (closest == nil or candidate.HitTime < closest.HitTime) then
			closest = candidate
		end
	end
	if not closest then
		RegisterGhostMiss(side, lane)
		return
	end

	local offsetMS = now - closest.HitTime
	local absOffset = math.abs(offsetMS)
	if offsetMS < -BadWindow then
		-- way too early, this note isnt even close yet
		RegisterGhostMiss(side, lane)
		return
	end
	if absOffset > BadWindow then
		RegisterGhostMiss(side, lane, closest)
		return
	end
	JudgeAndConsume(closest, absOffset)
end

local function Press(side: Side, lane: string)
	if not GetReceptor(side, lane) then
		warn("Direction not found: " .. tostring(lane))
		return
	end
	SetReceptorPressed(side, lane)
	HeldKeys[side][lane] = true
	HandlePress(side, lane)
end

local function Release(side: Side, lane: string)
	SetReceptorReleased(side, lane)
	HeldKeys[side][lane] = false
	ScheduleIdle(side)
end

-- note spawning

local function SpawnNoteForSide(hitTime: number, laneName: string, duration: number?, side: Side)
	local track = SideUIs[side].Track
	local template = track:FindFirstChild(laneName)
	if not template or not template:IsA("ImageLabel") then
		warn("SpawnNote: arrow template '" .. laneName .. "' not found under " .. track:GetFullName())
		return
	end

	local arrow = template:Clone() :: ImageLabel
	arrow.Parent = track
	arrow.ImageTransparency = 0
	arrow.Visible = true

	local startPos = arrow.Position
	local target = GetHoldTarget(side, laneName)
	if target then
		-- line the arrow up with its receptor horizontally, keep its own starting Y
		startPos = UDim2.new(target.Position.X.Scale, target.Position.X.Offset, startPos.Y.Scale, startPos.Y.Offset)
		arrow.Position = startPos
	end

	local visualTravelTime = GetVisualTravelTime()
	local note: Note = {
		HitTime = hitTime,
		Duration = duration,
		Instance = arrow,
		Lane = laneName,
		Side = side,
		StartPos = startPos,
		StartY = startPos.Y.Scale,
		SpawnSongTimeMS = hitTime - visualTravelTime,
		VisualTravelTime = visualTravelTime,
		Judged = false,
		IsHold = false,
		HoldActive = false,
		HoldDurationMS = nil,
		HoldEndSongTimeMS = nil,
		HoldTrail = nil,
	}

	if IsHoldNote(note) then
		note.HoldTrail = CreateHoldTrail(note)
		PositionApproachingHoldTrail(note, note.StartY)
	end

	local lanes = ActiveNotes[side]
	local list = lanes[laneName]
	if not list then
		list = {}
		lanes[laneName] = list
	end
	table.insert(list, note)
end

local function SpawnNote(hitTime: number, lane: number, duration: number?)
	local laneName = LaneMap[lane]
	if typeof(laneName) ~= "string" then
		return
	end
	SpawnNoteForSide(hitTime, laneName, duration, GetSide(lane))
end

-- the big heartbeat loop
-- one connection for everything (it used to be two). order matters here:
-- spawn notes that are due, let the bot play, then move / judge / expire every note

local function SpawnDueNotes(songNowMS: number)
	local lookAheadMS = GetVisualTravelTime()
	local chartNote = ActiveChart[ChartStep]
	while chartNote and songNowMS >= (chartNote.t - lookAheadMS) do
		SpawnNote(chartNote.t, chartNote.l, chartNote.d)
		if chartNote.k and ChartKeyEvent then
			ChartKeyEvent:Fire(tostring(chartNote.k))
		end
		ChartStep += 1
		chartNote = ActiveChart[ChartStep]
	end
end

local function StepBotplay(botSide: Side, songNowMS: number)
	for lane, list in pairs(ActiveNotes[botSide]) do
		for _, note in ipairs(list) do
			if not note.Judged and songNowMS >= note.HitTime then
				SetReceptorPressed(botSide, lane)
				JudgeAndConsume(note, 0)
				if not IsHoldNote(note) then
					task.delay(BOT_RELEASE_DELAY, function()
						SetReceptorReleased(botSide, lane)
					end)
				end
				break -- one note per lane per frame is plenty and the list just changed anyway
			end
		end
	end
end

local function StepNote(side: Side, lane: string, note: Note, songNowMS: number, botSide: Side)
	if note.Judged and note.IsHold and note.HoldActive then
		local remaining = (note.HoldEndSongTimeMS or 0) - songNowMS
		local isHeld: boolean
		if side == botSide and BotplayEnabled then
			isHeld = true
		else
			isHeld = HeldKeys[side][lane] == true
		end
		if not isHeld or remaining <= 0 then
			EndHold(note)
		else
			UpdateHoldTrail(note, remaining)
		end
		return
	end

	-- still flying toward the receptor
	local elapsedMS = songNowMS - note.SpawnSongTimeMS
	local progress = math.max(elapsedMS / note.VisualTravelTime, 0)
	local newY = note.StartY + (GetTargetY(side, lane) - note.StartY) * progress
	note.Instance.Position = UDim2.new(note.StartPos.X.Scale, note.StartPos.X.Offset, newY, note.StartPos.Y.Offset)
	if note.HoldTrail then
		PositionApproachingHoldTrail(note, newY)
	end

	-- sailed past the hit window untouched = miss. rip
	if songNowMS - note.HitTime > BadWindow then
		ApplyJudgement(side, "Miss")
		PlayMissAnim(side, lane)
		RemoveNote(note)
		ScheduleIdle(side)
	end
end

local function Step()
	if not MainAudioObject then
		return
	end
	local songNowMS = GetSongTimeMS()
	local botSide = OppositeSide(LocalSide)

	CameraHandle.Update(songNowMS)
	SpawnDueNotes(songNowMS)

	if BotplayEnabled then
		StepBotplay(botSide, songNowMS)
	end

	for _, side in ipairs(SIDES) do
		for lane, list in pairs(ActiveNotes[side]) do
			-- backwards so removing stuff doesnt skip the next note
			for i = #list, 1, -1 do
				local note = list[i]
				if note then
					StepNote(side, lane, note, songNowMS, botSide)
				end
			end
		end
	end
end

local HeartbeatConnection = RunService.Heartbeat:Connect(Step)

-- song lifecycle

local function StopCurrentSong()
	for _, audio in ipairs(ActiveSongAudios) do
		audio:Stop()
	end
	ActiveSongAudios = {}
end

-- kills everything song related. used by EndSong and by LoadSong (when a match is
-- already running and somebody just yeets a new song at us)
local function TeardownMatch(resetOpponent: boolean)
	-- bump the generation FIRST so nothing from the old song can fire callbacks mid teardown
	SongGeneration += 1
	StopCurrentSong()

	MainAudioObject = nil
	AudioStarted = false
	SongLeadInStartClock = nil
	SongLeadInDelayMS = 0
	ActiveChart = {}
	ChartStep = 1
	ChartKeyEvent = nil

	MatchActive = false
	RefreshWatcherState()
	CameraHandle.Reset()
	ResetAllHoldCovers()
	ResetAllSickSplashes()

	for _, side in ipairs(SIDES) do
		for _, list in pairs(ActiveNotes[side]) do
			for _, note in ipairs(list) do
				DestroyNote(note)
			end
		end
		ActiveNotes[side] = {}
		HeldKeys[side] = {}
		Slots[side].IdleToken += 1 -- cancels any pending idle timers
	end

	if resetOpponent then
		ResetOpponentCharacter()
	end
	PlayIdle("Player")
	ResetStats()
end

local function EndSong()
	if not MatchActive then
		return -- already ended. audio.Ended and a manual call can race so this saves us
	end
	ComputeMatchWinner()
	TeardownMatch(true)
	-- copy the list so callbacks can unsubscribe themselves without breaking the loop,
	-- and task.spawn so one busted callback doesnt take the rest down with it
	for _, callback in ipairs(table.clone(SongEndCallbacks)) do
		task.spawn(callback)
	end
end

-- pulls scroll speed and bpm out of the song module. it can be a number, a table keyed
-- by difficulty, or nothing at all. charters were creative
local function ResolveScrollAndBPM(songModule: SongModule, difficulty: string): (number, number)
	local speed = Config.DefaultScrollSpeed
	local bpm = Config.DefaultBPM
	local scroll = songModule.ScrollSpeed

	if typeof(scroll) == "number" then
		speed = scroll
	elseif typeof(scroll) == "table" then
		local lowerDifficulty = string.lower(difficulty)
		for key, value in pairs(scroll) do
			if string.lower(key) == lowerDifficulty then
				if typeof(value) == "table" then
					speed = value.ScrollSpeed or speed
					bpm = value.BPM or bpm
				elseif typeof(value) == "number" then
					speed = value
				end
				break
			end
		end
	end
	return math.max(speed, MIN_SCROLL_SPEED), bpm
end

-- cleans up the raw chart: drops junk notes, sorts if needed, counts notes per side
local function BuildChart(raw: { ChartNote }): ({ ChartNote }, { [Side]: number })
	local clean: { ChartNote } = {}
	local counts: { [Side]: number } = { Player = 0, Opponent = 0 }
	local sorted = true
	local lastTime = -math.huge

	for _, note in ipairs(raw) do
		if typeof(note.t) == "number" and typeof(note.l) == "number" and typeof(LaneMap[note.l]) == "string" then
			if note.t < lastTime then
				sorted = false
			end
			lastTime = note.t
			table.insert(clean, note)
			counts[GetSide(note.l)] += 1
		end
	end

	if not sorted then
		warn("chart wasn't sorted by time. sorting it for you, you're welcome")
		table.sort(clean, function(a, b)
			if a.t ~= b.t then
				return a.t < b.t -- types unknown and unknown I DONT CARE AHHHHHHHHHHHHHH
			end
			return a.l < b.l
		end)
	end
	return clean, counts
end

local function LoadSong(songName: string, difficulty: string): boolean
	if MatchActive then
		TeardownMatch(false)
	end
	StopCurrentSong()

	-- validate everything BEFORE touching state. otherwise a mistyped song name leaves us stuck "in a match" forever
	local songFolder = SongCatalog.FindSongModule(songName)
	if not songFolder then
		warn("LoadSong: no song module found named '" .. songName .. "'")
		return false
	end

	local requireOk, moduleResult = pcall(function()
		return require(songFolder)
	end)
	if not requireOk then
		warn("LoadSong: song module '" .. songName .. "' errored: " .. tostring(moduleResult))
		return false
	end
	local songModule = moduleResult :: SongModule

	local rawChart = if songModule.Charts then songModule.Charts[difficulty] else nil
	if not rawChart then
		warn("LoadSong: '" .. songName .. "' has no chart for difficulty '" .. difficulty .. "'")
		return false
	end

	local separateChartPrefix = SongCatalog.GetSeparateChartPrefix(songName, difficulty)
	local mainAudioName = if separateChartPrefix then separateChartPrefix .. "inst" else "inst"
	local songAudios = SongCatalog.GetSongAudio(songName, difficulty, songFolder)
	local mainAudio: Sound? = nil
	for _, audio in ipairs(songAudios) do
		if audio.Name == mainAudioName then
			mainAudio = audio
			break
		end
	end
	if not mainAudio then
		warn("LoadSong: main audio '" .. mainAudioName .. "' not found for " .. songName)
		return false
	end

	-- all good, were committed now. no going back
	MatchActive = true
	RefreshWatcherState()

	local anyModule = songModule :: any
	CameraHandle.LoadEvents(anyModule["Events_" .. string.lower(difficulty)] or anyModule.Events)

	local chart, counts = BuildChart(rawChart)
	ActiveChart = chart
	ChartStep = 1
	Stats.Player.TotalNotes = counts.Player
	Stats.Opponent.TotalNotes = counts.Opponent

	local keyEvent = script:FindFirstChild("Event")
	ChartKeyEvent = if keyEvent and keyEvent:IsA("BindableEvent") then keyEvent else nil

	local songBPM: number
	ScrollSpeed, songBPM = ResolveScrollAndBPM(songModule, difficulty)
	CameraHandle.SetBPM(songBPM)

	-- if the first note is too early to watch it travel, hold the audio back so the player isnt ambushed
	local leadInDelayMS = 0
	local firstNote = chart[1]
	if firstNote then
		leadInDelayMS = math.max(GetVisualTravelTime() - firstNote.t, 0)
	end

	print("Song Name: " .. songName .. " Difficulty: " .. difficulty)

	SongGeneration += 1
	local myGeneration = SongGeneration
	MainAudioObject = mainAudio
	ActiveSongAudios = songAudios
	AudioStarted = false
	SongLeadInDelayMS = leadInDelayMS
	SongLeadInStartClock = os.clock()

	local function BeginAudioPlayback()
		if myGeneration ~= SongGeneration or AudioStarted then
			return
		end
		AudioStarted = true
		for _, audio in ipairs(songAudios) do
			audio:Play()
		end
		mainAudio.Ended:Once(function()
			if myGeneration == SongGeneration then
				EndSong()
			end
		end)
	end

	if leadInDelayMS > 0 then
		task.delay(leadInDelayMS / 1000, BeginAudioPlayback)
	else
		BeginAudioPlayback()
	end

	return true
end

-- public api

-- returns an unsubscribe function, because leaking callbacks is how you get haunted uis
function ArrowHandle.OnSongEnd(callback: () -> ()): () -> ()
	table.insert(SongEndCallbacks, callback)
	return function()
		local idx = table.find(SongEndCallbacks, callback)
		if idx then
			table.remove(SongEndCallbacks, idx)
		end
	end
end

function ArrowHandle.LoadSong(songName: string, difficulty: string): boolean
	return LoadSong(songName, difficulty)
end

function ArrowHandle.EndSong()
	EndSong()
end

function ArrowHandle.SpawnNote(endtime: number, lane: number, duration: number?)
	SpawnNote(endtime, lane, duration)
end

function ArrowHandle.GetSongTime(): number
	return GetSongTimeMS()
end

function ArrowHandle.SetSongSelectionActive(active: boolean)
	if SongSelectionActive == active then
		return
	end
	SongSelectionActive = active
	RefreshWatcherState()
end

function ArrowHandle.SetPlayerCharacter(characterName: string)
	ApplyCharacter("Player", characterName)
end

function ArrowHandle.SetOpponentCharacter(characterName: string)
	ApplyCharacter("Opponent", characterName)
end

function ArrowHandle.SetOpponentCharacterFromPlayer(opponentPlayer: Player?)
	-- every call gets an id. if a newer call shows up while were waiting the older one bails
	OpponentRequestId += 1
	local requestId = OpponentRequestId
	DisconnectWatcher(OpponentWatcher)
	OpponentWatcher.Value = nil

	if not opponentPlayer then
		ApplyCharacter(OppositeSide(LocalSide), DEFAULT_CHARACTER)
		return
	end

	local charString = opponentPlayer:WaitForChild("charString", CHARACTER_STRING_TIMEOUT)
	if requestId ~= OpponentRequestId then
		return
	end
	if not charString or not charString:IsA("StringValue") then
		warn("SetOpponentCharacterFromPlayer: no charString on " .. opponentPlayer.Name .. ", using default")
		ApplyCharacter(OppositeSide(LocalSide), DEFAULT_CHARACTER)
		return
	end

	OpponentWatcher.Value = charString
	ApplyCharacter(OppositeSide(LocalSide), charString.Value)
	if not IsCharacterLocked() then
		ConnectWatcher(OpponentWatcher, GetOpponentDisplaySide)
	end
end

function ArrowHandle.ResetOpponentCharacter()
	ResetOpponentCharacter()
end

function ArrowHandle.PlayHey()
	PlayTimedAnim("Player", Slots.Player.Prefix .. " HEY", HEY_FROZEN_SECONDS)
end

function ArrowHandle.PlayFrozen()
	PlayTimedAnim("Player", Slots.Player.Prefix .. " FROZEN", HEY_FROZEN_SECONDS)
end

function ArrowHandle.SetScrollSpeed(multiplier: number)
	ScrollSpeed = math.max(multiplier, MIN_SCROLL_SPEED)
end

function ArrowHandle.SetBotplayEnabled(enabled: boolean)
	BotplayEnabled = enabled
end

function ArrowHandle.SetLocalSide(side: Side)
	if LocalSide == side then
		return
	end
	LocalSide = side
	RefreshWatcherState()
end

function ArrowHandle.SetWinCondition(condition: string)
	CurrentWinCondition = condition
end

function ArrowHandle.GetWinCondition(): string
	return CurrentWinCondition
end

function ArrowHandle.GetLastMatchWinner(): string?
	return LastMatchWinner
end

function ArrowHandle.SetGhostTapProtection(enabled: boolean)
	GhostTapProtectionEnabled = enabled
end

function ArrowHandle.GetScore(side: Side?): number
	return Stats[side or LocalSide].Score
end

function ArrowHandle.GetAccuracy(side: Side?): number
	return GetAccuracy(side or LocalSide)
end

function ArrowHandle.GetClickCount(): number
	return ClickCount
end

-- input entry points. no task.spawn needed, none of this yields (i checked. twice)
function ArrowHandle.PressedArrow(direction: string)
	Press(LocalSide, direction)
end

function ArrowHandle.ReleasedArrow(direction: string)
	ClickCount += 1
	Release(LocalSide, direction)
end

function ArrowHandle.PressedArrowOpponent(direction: string)
	Press(OppositeSide(LocalSide), direction)
end

function ArrowHandle.ReleasedArrowOpponent(direction: string)
	Release(OppositeSide(LocalSide), direction)
end

-- optional manual cleanup for when the whole ui is getting torn down
function ArrowHandle.Destroy()
	HeartbeatConnection:Disconnect()
	DisconnectWatcher(LocalWatcher)
	DisconnectWatcher(OpponentWatcher)
	TeardownMatch(true)
	table.clear(SongEndCallbacks)
end

-- init

-- the charString might not exist yet when this loads. waiting for it in a spawn means the
-- module returns right away instead of hanging every script that requires us
task.spawn(function()
	local charString = LocalPlayer:WaitForChild("charString", 10)
	if not charString or not charString:IsA("StringValue") then
		warn("ArrowHandle: LocalPlayer.charString never showed up, sticking with the default skin")
		return
	end
	LocalWatcher.Value = charString
	ApplyCharacter(LocalSide, charString.Value)
	if not IsCharacterLocked() then
		ConnectWatcher(LocalWatcher, GetLocalDisplaySide)
	end
end)

ApplyCharacter(OppositeSide(LocalSide), DEFAULT_CHARACTER)

return ArrowHandle
