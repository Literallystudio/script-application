--// Connected Discord-GitHub
--!strict

--// services

local replicated_storage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local http_service = game:GetService("HttpService")
local data_store_service = game:GetService("DataStoreService")

--// types

type Role = "Player" | "Opponent"
type Side = "Left" | "Right"
type Joinable = "Everyone" | "Nobody"
type WinCondition = "Score" | "Accuracy" | "Misses"
type Direction = "UP" | "DOWN" | "LEFT" | "RIGHT"
type PressKind = "press" | "release"

type Payload = {[string]: unknown} --// whatever a client sends, nothing in it is trusted till it goes thru one of the checks below

type Note = {t: number, d: number?} --// d is an optional length on top of the note time
type Chart = {Note}
type SongChoice = {song: string, difficulty: string, chart: Chart}
type SongPick = {song: string, difficulty: string}
type PressEvent = {t: PressKind, d: Direction}

type SongModule = {Songs: {string}}
type SongCatalogApi = {
	Get: () -> {SongModule},
	FindSongModule: (song: string) -> ModuleScript?,
	IsSoloOnly: (song: string, difficulty: string) -> boolean,
	HasAnySoloRestriction: (song: string) -> boolean,
}
type ConfigApi = {MaxScore: number}

type PlayerStats = {Wins: number, Losses: number, Draws: number, Streak: number, BestStreak: number} --// these keys are whats saved in the datastore so the casing stays
type Leaderstats = {Wins: IntValue, Losses: IntValue, Streak: IntValue}
type MatchReport = {score: number, accuracy: number, forfeited: boolean}

type PartyListing = {Id: string, PartyName: string, Side: Side, Joinable: Joinable, WinCondition: WinCondition, RankedBy: WinCondition}

--// everything the server can send on PvPRemote, payload.a tells the client which one it is
type ServerMessage =
	{a: "Waiting", song: string, difficulty: string}
| {a: "Matched", role: Role, opponent: string, song: string, difficulty: string, countdown: number, matchId: string}
| {a: "OpponentLeft"}
| {a: "StatsUpdated", stats: PlayerStats}
| {a: "PartyListUpdated", parties: {PartyListing}}
| {a: "PartyReady", role: Role, opponent: string, matchId: string, pickSeconds: number}

--// modules

local SongCatalog = require(replicated_storage.ClientModules.SongCatalog) :: SongCatalogApi --// both are in repstorage so the client can read the same catalog and config
local Config = require(replicated_storage.ClientModules.Config) :: ConfigApi --// casts cuz require hands back any and i only touch these bits

--// remotes

local function make_remote(class_name: string, name: string): Instance
	local remote = Instance.new(class_name)
	remote.Name = name
	remote.Parent = replicated_storage --// made here so i dont gotta pre build them in the place file
	return remote
end

local press_relay = make_remote("RemoteEvent", "PressRelay") :: RemoteEvent --// note presses, just gets sent straight to the opponent
local pvp_remote = make_remote("RemoteEvent", "PvPRemote") :: RemoteEvent --// queue, party and result stuff all comes thru here, payload.a says which one
local pvp_stats_function = make_remote("RemoteFunction", "PvPStatsFunction") :: RemoteFunction
local match_stats_store = data_store_service:GetDataStore("PvPStats_v1")

--// settings

local max_events_per_batch = 40
local max_batches_per_second = 30 --// presses spam a lot so batches get a way higher cap than menu stuff
local max_actions_per_second = 5
local countdown_seconds = 3
local min_match_duration_seconds = 5
local pick_seconds = 15 --// how long both ppl have to send PickSong after the party fills

--// each one maps a string to itself, the point is indexing one hands back the typed version and not just a string
local valid_directions: {[string]: Direction} = {UP = "UP", DOWN = "DOWN", LEFT = "LEFT", RIGHT = "RIGHT"}
local valid_press_kinds: {[string]: PressKind} = {press = "press", release = "release"}
local valid_sides: {[string]: Side} = {Left = "Left", Right = "Right"}
local valid_joinable: {[string]: Joinable} = {Everyone = "Everyone", Nobody = "Nobody"}
local valid_win_conditions: {[string]: WinCondition} = {Score = "Score", Accuracy = "Accuracy", Misses = "Misses"}

--// checks, anything from a client is unknown till it gets thru one of these

local function read_string(value: unknown): string?
	return if typeof(value) == "string" then value else nil
end

local function read_number(value: unknown): number?
	return if typeof(value) == "number" then value else nil
end

local function read_key(value: unknown): string
	return read_string(value) or "" --// empty string isnt a key in any whitelist so anything that isnt a string just misses
end

--// charts

local function load_charts(song: string): {[string]: Chart}?
	local song_module = SongCatalog.FindSongModule(song)
	if not song_module then return nil end
	local success, data = pcall(require, song_module) --// pcall so one broken song module doesnt error the whole handler
	if not success or typeof(data) ~= "table" or typeof(data.Charts) ~= "table" then return nil end
	return data.Charts :: {[string]: Chart} --// the song modules are mine so i trust the shape once its a table
end

--// one spot decides whats playable so queue, party picks and the random fallback cant disagree
local function get_pvp_chart(song: string, difficulty: string): Chart?
	local charts = load_charts(song)
	if not charts then return nil end
	for chart_difficulty, chart in charts do
		if string.lower(chart_difficulty) == string.lower(difficulty) then --// clients can send any casing
			return if SongCatalog.IsSoloOnly(song, difficulty) then nil else chart
		end
	end
	return nil
end

local function get_random_song_pick(): SongChoice?
	local candidates: {string} = {}
	for _, song_module in ipairs(SongCatalog.Get()) do
		for _, song in ipairs(song_module.Songs) do
			if not SongCatalog.HasAnySoloRestriction(song) then table.insert(candidates, song) end
		end
	end
	if #candidates == 0 then return nil end
	local song = candidates[math.random(1, #candidates)]
	local charts = load_charts(song)
	if not charts then return nil end
	local difficulties: {string} = {}
	for difficulty in charts do
		if not SongCatalog.IsSoloOnly(song, difficulty) then table.insert(difficulties, difficulty) end
	end
	if #difficulties == 0 then return nil end
	local difficulty = difficulties[math.random(1, #difficulties)]
	local chart = get_pvp_chart(song, difficulty)
	return if chart then {song = song, difficulty = difficulty, chart = chart} else nil
end

local function get_min_duration(chart: Chart): number
	local last_note_end = 0
	for _, note in ipairs(chart) do
		last_note_end = math.max(last_note_end, note.t + (if typeof(note.d) == "number" then note.d else 0))
	end
	return math.max(last_note_end / 1000 * 0.85, min_match_duration_seconds) --// note times are in ms, floor is 85% of the last note time but never under the min
end

--// classes, each one owns its own data and the methods that touch it. the server wide tables that connect them are in state

--// rate limiter, one small table per player instead of a list of timestamps

type RateWindow = {count: number, window_start: number}
type RateLimiterFields = {max_per_second: number, windows: {[Player]: RateWindow}}

local RateLimiter = {}
RateLimiter.__index = RateLimiter
type RateLimiter = typeof(setmetatable({} :: RateLimiterFields, RateLimiter))

function RateLimiter.new(max_per_second: number): RateLimiter
	return setmetatable({max_per_second = max_per_second, windows = {}}, RateLimiter)
end

function RateLimiter.is_limited(self: RateLimiter, player: Player): boolean
	local now = os.clock()
	local window = self.windows[player]
	if not window or now - window.window_start >= 1 then
		self.windows[player] = {count = 1, window_start = now} --// fixed 1 sec window
		return false
	end
	window.count += 1
	return window.count > self.max_per_second
end

function RateLimiter.forget(self: RateLimiter, player: Player)
	self.windows[player] = nil
end

--// match queue, one waiting player per song / difficulty key

type MatchQueueFields = {waiting: {[string]: Player}, keys: {[Player]: string}}

local MatchQueue = {}
MatchQueue.__index = MatchQueue
type MatchQueue = typeof(setmetatable({} :: MatchQueueFields, MatchQueue))

function MatchQueue.new(): MatchQueue
	return setmetatable({waiting = {}, keys = {}}, MatchQueue) --// keys is the reverse lookup so someone leaving can find their slot
end

function MatchQueue.clear(self: MatchQueue, player: Player)
	local key = self.keys[player]
	if key and self.waiting[key] == player then self.waiting[key] = nil end --// the slot might be someone elses by now
	self.keys[player] = nil
end

function MatchQueue.take(self: MatchQueue, key: string): Player?
	local waiting = self.waiting[key]
	if not waiting or not waiting.Parent then return nil end --// nobody there, or they left without clearing
	self.waiting[key] = nil
	self.keys[waiting] = nil
	return waiting
end

function MatchQueue.add(self: MatchQueue, player: Player, key: string)
	self.waiting[key] = player --// also covers a waiter that left w/o clearing, their old entry just gets replaced
	self.keys[player] = key
end

--// stats, values is the plain table that gets saved and sent, the metatable never leaves the server

type StatsFields = {user_id: number, values: PlayerStats}

local Stats = {}
Stats.__index = Stats
type Stats = typeof(setmetatable({} :: StatsFields, Stats))

function Stats.new(user_id: number, saved: {[string]: unknown}): Stats
	local values: PlayerStats = {
		Wins = read_number(saved.Wins) or 0, --// saved data can be missing stuff or just be junk
		Losses = read_number(saved.Losses) or 0,
		Draws = read_number(saved.Draws) or 0,
		Streak = read_number(saved.Streak) or 0,
		BestStreak = read_number(saved.BestStreak) or 0,
	}
	return setmetatable({user_id = user_id, values = values}, Stats)
end

function Stats.add_win(self: Stats)
	local values = self.values
	values.Wins += 1
	values.Streak += 1
	values.BestStreak = math.max(values.BestStreak, values.Streak)
end

function Stats.add_loss(self: Stats)
	self.values.Losses += 1
	self.values.Streak = 0 --// loss resets the streak, draw doesnt touch it
end

function Stats.add_draw(self: Stats)
	self.values.Draws += 1
end

function Stats.save(self: Stats)
	local values = self.values
	task.spawn(pcall, match_stats_store.UpdateAsync, match_stats_store, tostring(self.user_id), function() return values end) --// spawned so a slow datastore cant hold up the match result
end

--// match, one per pair of players from the start till the result is decided

type MatchFields = {id: string, players: {Player}, start_time: number, min_duration: number, reports: {[Player]: MatchReport?}}

local Match = {}
Match.__index = Match
type Match = typeof(setmetatable({} :: MatchFields, Match))

function Match.new(id: string, first: Player, second: Player, chart: Chart): Match
	return setmetatable({id = id, players = {first, second}, start_time = os.clock(), min_duration = get_min_duration(chart), reports = {}}, Match)
end

function Match.has_reported(self: Match, player: Player): boolean
	return self.reports[player] ~= nil
end

function Match.is_too_early(self: Match): boolean
	return os.clock() - self.start_time < self.min_duration --// this stops instant fake results
end

function Match.submit(self: Match, player: Player, report: MatchReport)
	self.reports[player] = report
end

function Match.opponent_of(self: Match, player: Player): Player
	return if player == self.players[1] then self.players[2] else self.players[1]
end

--// gives back if both reports are in and who won (nil winner is a draw)
function Match.result(self: Match): (boolean, Player?)
	local first, second = self.players[1], self.players[2]
	local first_report, second_report = self.reports[first], self.reports[second]
	if not first_report or not second_report then return false, nil end --// still waiting on the other player
	if first_report.forfeited and second_report.forfeited then return true, nil end --// both left so no one wins
	if first_report.forfeited then return true, second end --// whoever forfeited loses no matter what the scores were
	if second_report.forfeited then return true, first end
	if first_report.score > second_report.score then return true, first end --// > both ways so equal scores fall thru to a draw
	if second_report.score > first_report.score then return true, second end
	return true, nil
end

--// party

type PartyFields = {
	id: string,
	owner: Player,
	members: {Player},
	side: Side,
	joinable: Joinable,
	win_condition: WinCondition,
	match_id: string?, --// nil while the party is open, when it fills this gets set and thats the lock
}

local Party = {}
Party.__index = Party
type Party = typeof(setmetatable({} :: PartyFields, Party))

function Party.new(owner: Player, side: Side, joinable: Joinable, win_condition: WinCondition): Party
	return setmetatable({id = http_service:GenerateGUID(false), owner = owner, members = {owner}, side = side, joinable = joinable, win_condition = win_condition, match_id = nil}, Party)
end

function Party.is_open_for(self: Party, viewer: Player): boolean
	return self.match_id == nil and self.joinable == "Everyone" and self.owner.Parent ~= nil and self.owner ~= viewer --// u never see ur own party as joinable
end

function Party.to_listing(self: Party): PartyListing
	return {
		Id = self.id,
		PartyName = `{self.owner.Name} Party`,
		Side = self.side,
		Joinable = self.joinable,
		WinCondition = self.win_condition,
		RankedBy = self.win_condition,
	}
end

function Party.lock(self: Party, joiner: Player, match_id: string)
	table.insert(self.members, joiner)
	self.match_id = match_id --// this is the lock, from here is_open_for is false and the party leaves every list
end

--// state

type PartyPick = {party: Party, picks: {[Player]: SongPick}}

local batch_limiter = RateLimiter.new(max_batches_per_second)
local action_limiter = RateLimiter.new(max_actions_per_second)
local match_queue = MatchQueue.new()
local active_matches: {[Player]: Player?} = {} --// player -> opponent, who presses get sent to
local player_match: {[Player]: Match?} = {} --// only lasts till the result is decided, not the whole match
local parties: {[string]: Party} = {}
local player_party_id: {[Player]: string} = {}
local pick_states: {[string]: PartyPick} = {} --// match id -> song picks of a full party
local stats_cache: {[number]: Stats} = {}
local player_leaderstats: {[Player]: Leaderstats} = {}

--// messaging

local function send(player: Player, message: ServerMessage)
	pvp_remote:FireClient(player, message)
end

local function notify_left(player: Player) --// same OpponentLeft whether they left or their party fell apart
	if player.Parent then send(player, {a = "OpponentLeft"}) end
end

--// stats

local function load_stats(user_id: number): Stats
	local cached = stats_cache[user_id]
	if cached then return cached end
	local success, data = pcall(function() return match_stats_store:GetAsync(tostring(user_id)) end)
	local saved = if success and typeof(data) == "table" then data :: {[string]: unknown} else {} --// failed read and brand new player both just start at 0
	local stats = Stats.new(user_id, saved)
	stats_cache[user_id] = stats --// this exact object is what results edit + save so theres only ever one copy
	return stats
end

local function make_int_value(parent: Instance, name: string): IntValue
	local value = Instance.new("IntValue")
	value.Name = name
	value.Parent = parent
	return value
end

local function create_leaderstats(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats" --// roblox needs this exact name to show it on the player list
	player_leaderstats[player] = {
		Wins = make_int_value(folder, "Wins"),
		Losses = make_int_value(folder, "Losses"),
		Streak = make_int_value(folder, "Streak"),
	}
	folder.Parent = player --// parented last so the client gets it with the values already in it
end

local function sync_leaderstats(player: Player, values: PlayerStats)
	local leaderstats = player_leaderstats[player]
	if not leaderstats then return end --// gets removed on leave, and a stats load can finish after that
	leaderstats.Wins.Value = values.Wins
	leaderstats.Losses.Value = values.Losses
	leaderstats.Streak.Value = values.Streak
end

local function push_stats(player: Player, stats: Stats)
	if not player.Parent then return end --// they already left, no1 to tell
	sync_leaderstats(player, stats.values)
	send(player, {a = "StatsUpdated", stats = stats.values})
end

--// results

local function record_win(winner: Player, loser: Player)
	local winner_stats, loser_stats = load_stats(winner.UserId), load_stats(loser.UserId) --// these can yield if the cache is cold
	winner_stats:add_win()
	loser_stats:add_loss()
	winner_stats:save()
	loser_stats:save()
	push_stats(winner, winner_stats)
	push_stats(loser, loser_stats)
end

local function record_draw(first: Player, second: Player)
	for _, player in {first, second} do
		local stats = load_stats(player.UserId)
		stats:add_draw()
		stats:save()
		push_stats(player, stats)
	end
end

local function try_resolve_match(match: Match)
	local done, winner = match:result()
	if not done then return end
	local first, second = match.players[1], match.players[2]
	player_match[first] = nil --// cleared before record_win cuz it can yield, so a late report finds no match and cant resolve it twice
	player_match[second] = nil
	if winner == nil then
		record_draw(first, second)
	else
		record_win(winner, match:opponent_of(winner))
	end
end

local function forfeit_match(player: Player)
	local match = player_match[player]
	if not match or match:has_reported(player) then return end --// no match, or they already reported so leaving doesnt cost them
	match:submit(player, {score = 0, accuracy = 0, forfeited = true}) --// the flag decides the result, score never gets compared
	try_resolve_match(match)
end

--// matches

local function make_queue_key(song: string, difficulty: string): string
	return string.lower(song) .. "|" .. string.lower(difficulty) --// lowercased so diff casing cant put ppl in separate queues
end

local function end_match(player: Player)
	local opponent = active_matches[player]
	if not opponent then return end
	active_matches[player] = nil
	active_matches[opponent] = nil --// both get cleared together so presses stop relaying both ways
	notify_left(opponent)
end

local function role_for_side(side: Side): Role
	return if side == "Right" then "Player" else "Opponent"
end

local function opposite_role(role: Role): Role
	return if role == "Player" then "Opponent" else "Player"
end

local function announce_match(player: Player, role: Role, opponent: Player, choice: SongChoice, match_id: string)
	send(player, {a = "Matched", role = role, opponent = opponent.Name, song = choice.song, difficulty = choice.difficulty, countdown = countdown_seconds, matchId = match_id})
end

--// queue and party pick both end up here so matches get set up the same either way
local function start_match(match_id: string, first: Player, first_role: Role, second: Player, choice: SongChoice)
	local match = Match.new(match_id, first, second, choice.chart)
	player_match[first] = match
	player_match[second] = match
	active_matches[first] = second
	active_matches[second] = first
	announce_match(first, first_role, second, choice, match_id)
	announce_match(second, opposite_role(first_role), first, choice, match_id)
end

--// parties

--// if ur already queued, matched or in a party u cant start another one
local function is_busy(player: Player): boolean
	return active_matches[player] ~= nil or player_match[player] ~= nil or player_party_id[player] ~= nil
end

local function build_open_party_list(viewer: Player): {PartyListing}
	local list: {PartyListing} = {}
	for _, party in parties do
		if party:is_open_for(viewer) then table.insert(list, party:to_listing()) end
	end
	return list
end

local function send_party_list(player: Player)
	send(player, {a = "PartyListUpdated", parties = build_open_party_list(player)})
end

local function broadcast_party_list()
	for _, player in players:GetPlayers() do
		send_party_list(player) --// built per player cuz everyone has their own party left out
	end
end

local function cleanup_party_state(player: Player)
	local party_id = player_party_id[player]
	local party = if party_id then parties[party_id] else nil
	player_party_id[player] = nil
	if not party then return end
	parties[party.id] = nil
	local match_id = party.match_id
	if match_id == nil then
		broadcast_party_list() --// an open party is gone so every list is outdated
	else
		pick_states[match_id] = nil --// the pick timer still fires later but theres nothing there
		for _, member in party.members do
			if member == player then continue end
			player_party_id[member] = nil
			notify_left(member)
		end
	end
end

--// picked song only counts if its still playable (match needs its chart anyway), otherwise random
local function choose_party_song(pick: SongPick?): SongChoice?
	local chart = if pick then get_pvp_chart(pick.song, pick.difficulty) else nil
	if pick and chart then return {song = pick.song, difficulty = pick.difficulty, chart = chart} end
	return get_random_song_pick()
end

local function resolve_party_pick(match_id: string)
	local pick_state = pick_states[match_id]
	if not pick_state then return end --// someone left before the timer ran and cleanup already got it
	pick_states[match_id] = nil
	local party = pick_state.party
	parties[party.id] = nil
	local owner, joiner = party.members[1], party.members[2]
	player_party_id[owner] = nil --// party is done from here on whether a match starts or not
	player_party_id[joiner] = nil
	if not owner.Parent or not joiner.Parent then return end
	local chosen = party.members[math.random(1, 2)] --// only one of the two picks gets played
	local choice = choose_party_song(pick_state.picks[chosen])
	if choice then
		start_match(match_id, owner, role_for_side(party.side), joiner, choice)
	else
		notify_left(owner) --// nothing playable at all so both get the same OpponentLeft a leaver would cause
		notify_left(joiner)
	end
end

local function announce_party_ready(player: Player, role: Role, opponent: Player, match_id: string)
	send(player, {a = "PartyReady", role = role, opponent = opponent.Name, matchId = match_id, pickSeconds = pick_seconds})
end

--// dying only backs u out of stuff that isnt locked in yet
local function handle_reset(player: Player)
	if player_match[player] or active_matches[player] then return end
	match_queue:clear(player)
	local party_id = player_party_id[player]
	local party = if party_id then parties[party_id] else nil
	if party and party.match_id == nil then cleanup_party_state(player) end --// full party is already in its pick window so leave it alone
end

local function hook_character(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then return end
	humanoid.Died:Connect(function() handle_reset(player) end)
end

--// actions, every handler gets the player + raw payload, anything in it can be junk cuz it came from a client
--// ids get read as strings first, a wrong type id turns into nil and never matches anything real

local handlers: {[string]: (Player, Payload) -> ()} = {}

handlers.Queue = function(player: Player, payload: Payload)
	if active_matches[player] then return end
	local song, difficulty = read_string(payload.song), read_string(payload.difficulty)
	if not song or not difficulty then return end
	local chart = get_pvp_chart(song, difficulty)
	if not chart then return end
	match_queue:clear(player) --// one slot per player, and this frees their old slot so they cant match w themselves
	local key = make_queue_key(song, difficulty)
	local waiting = match_queue:take(key)
	if waiting then
		start_match(http_service:GenerateGUID(false), waiting, "Player", player, {song = song, difficulty = difficulty, chart = chart}) --// whoever waited first is the Player
	else
		match_queue:add(player, key)
		send(player, {a = "Waiting", song = song, difficulty = difficulty})
	end
end

handlers.Cancel = function(player: Player)
	match_queue:clear(player)
end

handlers.EndMatch = function(player: Player)
	forfeit_match(player) --// records the loss first, then end_match unlinks them and tells the opponent
	end_match(player)
end

handlers.ReportResult = function(player: Player, payload: Payload)
	local score, accuracy = read_number(payload.score), read_number(payload.accuracy)
	if not score or not accuracy then return end
	local match = player_match[player]
	if not match or match.id ~= read_string(payload.matchId) then return end --// has to be the match theyre actually in and not decided yet
	if match:has_reported(player) then return end --// first report counts, no resending
	if match:is_too_early() then return end --// too early to be a real finish
	match:submit(player, {score = math.clamp(score, 0, Config.MaxScore), accuracy = math.clamp(accuracy, 0, 100), forfeited = false})
	try_resolve_match(match)
end

handlers.CreateParty = function(player: Player, payload: Payload)
	if is_busy(player) then return end
	local side: Side? = valid_sides[read_key(payload.side)]
	local joinable: Joinable? = valid_joinable[read_key(payload.joinable)]
	local win_condition: WinCondition? = valid_win_conditions[read_key(payload.winCondition)]
	if not (side and joinable and win_condition) then return end --// the whitelists double as type checks
	local party = Party.new(player, side, joinable, win_condition)
	parties[party.id] = party
	player_party_id[player] = party.id
	if joinable == "Everyone" then broadcast_party_list() end
end

handlers.JoinParty = function(player: Player, payload: Payload)
	if is_busy(player) then return end
	local party_id = read_string(payload.partyId)
	local party = if party_id then parties[party_id] else nil
	if not party or not party:is_open_for(player) then return end
	local match_id = http_service:GenerateGUID(false)
	party:lock(player, match_id)
	player_party_id[player] = party.id
	pick_states[match_id] = {party = party, picks = {}}
	broadcast_party_list()
	local owner_role: Role = role_for_side(party.side)
	announce_party_ready(party.owner, owner_role, player, match_id)
	announce_party_ready(player, opposite_role(owner_role), party.owner, match_id)
	task.delay(pick_seconds, resolve_party_pick, match_id) --// pick window ends here even if no1 picked
end

handlers.LeaveParty = function(player: Player)
	cleanup_party_state(player)
end

handlers.RequestPartyList = function(player: Player)
	send_party_list(player)
end

handlers.PickSong = function(player: Player, payload: Payload)
	local match_id = read_string(payload.matchId)
	local pick_state = if match_id then pick_states[match_id] else nil
	if not pick_state or not table.find(pick_state.party.members, player) then return end
	local song, difficulty = read_string(payload.song), read_string(payload.difficulty)
	if not song or not difficulty or not get_pvp_chart(song, difficulty) then return end
	pick_state.picks[player] = {song = song, difficulty = difficulty} --// last pick wins, and only one of the two picks gets used later
end

--// connections

local function sanitize_press(event: unknown): PressEvent?
	if typeof(event) ~= "table" then return nil end
	local fields = event :: Payload
	local kind: PressKind? = valid_press_kinds[read_key(fields.t)]
	local direction: Direction? = valid_directions[read_key(fields.d)]
	if not kind or not direction then return nil end
	return {t = kind, d = direction} --// rebuilt w just t and d so a client cant send extra fields to the opponent
end

pvp_remote.OnServerEvent:Connect(function(player: Player, payload: unknown)
	if typeof(payload) ~= "table" then return end
	local message = payload :: Payload
	local action = read_string(message.a)
	if not action then return end
	if action_limiter:is_limited(player) then return end
	local handler = handlers[action]
	if handler then handler(player, message) end
end)

press_relay.OnServerEvent:Connect(function(player: Player, events: unknown)
	if typeof(events) ~= "table" then return end
	local list = events :: {unknown}
	if #list > max_events_per_batch then return end
	if batch_limiter:is_limited(player) then return end
	local opponent = active_matches[player]
	if not opponent or not opponent.Parent then return end
	local sanitized: {PressEvent} = {}
	for _, event in ipairs(list) do --// ipairs only goes thru the array part, same part the size cap counted
		local press = sanitize_press(event)
		if press then table.insert(sanitized, press) end
	end
	if #sanitized == 0 then return end
	press_relay:FireClient(opponent, sanitized)
end)

pvp_stats_function.OnServerInvoke = function(player: Player): PlayerStats
	return load_stats(player.UserId).values
end

players.PlayerAdded:Connect(function(player: Player)
	create_leaderstats(player)
	task.spawn(function() sync_leaderstats(player, load_stats(player.UserId).values) end) --// spawned so the datastore read doesnt hold up the character hooks below
	player.CharacterAdded:Connect(function(character) hook_character(player, character) end)
	if player.Character then hook_character(player, player.Character) end
end)

players.PlayerRemoving:Connect(function(player: Player)
	batch_limiter:forget(player)
	action_limiter:forget(player)
	stats_cache[player.UserId] = nil
	player_leaderstats[player] = nil
	match_queue:clear(player)
	cleanup_party_state(player)
	forfeit_match(player)
	end_match(player)
end)
