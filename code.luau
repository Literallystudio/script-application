--// Connected Discord-GitHub
--!strict

--// services

local replicated_storage = game:GetService("ReplicatedStorage") --// remotes get made here and the shared catalog is read from here
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

type Note = {t: number, d: number?} --// t is the hit time in ms, d is an optional hold length on top of it
type Chart = {Note}
type SongChoice = {song: string, difficulty: string, chart: Chart} --// chart is carried along so the match doesnt have to look it up again
type SongPick = {song: string, difficulty: string} --// what a player sends in PickSong, no chart cuz its re checked later
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
type Leaderstats = {Wins: IntValue, Losses: IntValue, Streak: IntValue} --// the player list only shows these 3
type MatchReport = {score: number, forfeited: boolean} --// score is the only thing that decides a winner, forfeited overrides it

type PartyListing = {Id: string, PartyName: string, Side: Side, Joinable: Joinable, WinCondition: WinCondition, RankedBy: WinCondition}

--// everything the server can send on PvPRemote, payload.a tells the client which one it is
type ServerMessage =
	| {a: "Waiting", song: string, difficulty: string}
| {a: "Matched", role: Role, opponent: string, song: string, difficulty: string, countdown: number, matchId: string}
| {a: "OpponentLeft"}
| {a: "StatsUpdated", stats: PlayerStats}
| {a: "PartyListUpdated", parties: {PartyListing}}
| {a: "PartyReady", role: Role, opponent: string, matchId: string, pickSeconds: number}

--// modules

local SongCatalog = require(replicated_storage.ClientModules.SongCatalog) :: SongCatalogApi --// in repstorage so the client reads the exact same catalog the server validates against
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
local pvp_stats_function = make_remote("RemoteFunction", "PvPStatsFunction") :: RemoteFunction --// function and not an event cuz the client wants the stats handed back
local match_stats_store = data_store_service:GetDataStore("PvPStats_v1") --// versioned name so a format change later can start from a fresh store

--// settings

local max_events_per_batch = 40 --// checked before any looping so a huge batch costs nothing
local max_batches_per_second = 30 --// presses spam a lot so batches get a way higher cap than menu stuff
local max_actions_per_second = 5 --// menu actions are rare so a low cap is fine
local countdown_seconds = 3 --// goes out in Matched so both clients start their count together
local min_match_duration_seconds = 5 --// floor so a tiny chart still cant be finished instantly
local min_duration_ratio = 0.85 --// how much of the chart length a real run has to take at least
local pick_seconds = 15 --// how long both ppl have to send PickSong after the party fills

--// each one maps a string to itself, the point is indexing one hands back the typed version and not just a string
local valid_directions: {[string]: Direction} = {UP = "UP", DOWN = "DOWN", LEFT = "LEFT", RIGHT = "RIGHT"}
local valid_press_kinds: {[string]: PressKind} = {press = "press", release = "release"}
local valid_sides: {[string]: Side} = {Left = "Left", Right = "Right"}
local valid_joinable: {[string]: Joinable} = {Everyone = "Everyone", Nobody = "Nobody"}
local valid_win_conditions: {[string]: WinCondition} = {Score = "Score", Accuracy = "Accuracy", Misses = "Misses"}

--// checks, anything from a client is unknown till it gets thru one of these

local function read_string(value: unknown): string?
	return if typeof(value) == "string" then value else nil --// typeof narrows unknown to string for the return
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
	if not song_module then return nil end --// song name came from a client so it might not exist
	local success, data = pcall(require, song_module) --// pcall so one broken song module doesnt error the whole handler, require caches so calling this a lot is cheap
	if not success or typeof(data) ~= "table" then return nil end --// on a failed require data is just the error message, so the table check catches that too
	return data.Charts --// song modules are mine so the shape is trusted, a module w/o Charts just comes back nil like a missing song
end

--// one spot decides whats playable so queue, party picks and the random fallback cant disagree
local function get_pvp_chart(song: string, difficulty: string): Chart?
	local charts = load_charts(song)
	if not charts then return nil end
	local wanted = string.lower(difficulty) --// clients can send any casing, lowered once out here and not per loop
	for chart_difficulty, chart in charts do
		if string.lower(chart_difficulty) == wanted then --// lowered on both sides so hard finds Hard
			return if SongCatalog.IsSoloOnly(song, difficulty) then nil else chart --// a solo only chart exists but cant be played in pvp
		end
	end
	return nil
end

local function get_random_song_pick(): SongChoice?
	local candidates: {string} = {} --// flat list so every song has the same odds no matter which module holds it
	for _, song_module in SongCatalog.Get() do --// catalog data is mine so plain iteration, ipairs only matters on client tables
		for _, song in song_module.Songs do
			if not SongCatalog.HasAnySoloRestriction(song) then table.insert(candidates, song) end --// songs w a solo restriction stay out of the pool
		end
	end
	if #candidates == 0 then return nil end --// math.random errors on an empty range
	local song = candidates[math.random(#candidates)]
	local charts = load_charts(song)
	if not charts then return nil end
	local difficulties: {string} = {} --// charts is a dictionary so the names go in an array to pick one by index
	for difficulty in charts do
		table.insert(difficulties, difficulty) --// no solo check per difficulty, the candidate filter above already dropped any song that has one
	end
	local difficulty = difficulties[math.random(#difficulties)]
	return {song = song, difficulty = difficulty, chart = charts[difficulty]} --// charts are already loaded here so no need to go thru get_pvp_chart again
end

local function get_min_duration(chart: Chart): number
	local last_note_end = 0
	for _, note in chart do
		last_note_end = math.max(last_note_end, note.t + (note.d or 0)) --// max so it doesnt matter if the chart is sorted, a hold note ends at t + d
	end
	return math.max(last_note_end / 1000 * min_duration_ratio, min_match_duration_seconds) --// note times are in ms, the floor from settings keeps short charts honest
end

--// classes, each one owns its own data and the methods that touch it. the server wide tables that connect them are in state

--// rate limiter, one small table per player instead of a list of timestamps

type RateWindow = {count: number, window_start: number}
type RateLimiterFields = {max_per_second: number, windows: {[Player]: RateWindow}}

local RateLimiter = {}
RateLimiter.__index = RateLimiter --// so instances fall back to the methods below
type RateLimiter = typeof(setmetatable({} :: RateLimiterFields, RateLimiter)) --// lets strict mode type self in the methods

function RateLimiter.new(max_per_second: number): RateLimiter
	return setmetatable({max_per_second = max_per_second, windows = {}}, RateLimiter)
end

function RateLimiter.is_limited(self: RateLimiter, player: Player): boolean
	local now = os.clock() --// os.clock is monotonic so a clock change cant reopen a window
	local window = self.windows[player]
	if not window then
		window = {count = 0, window_start = now} --// first hit from this player, nothing to reuse yet
		self.windows[player] = window
	elseif now - window.window_start >= 1 then
		window.count = 0 --// fixed 1 sec window, the old table gets reused so presses dont make garbage
		window.window_start = now
	end
	window.count += 1 --// both branches above start from 0 so this hit is always counted the same way
	return window.count > self.max_per_second --// hits up to the cap go thru, the one after it is the first to get dropped
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
	if not key then return end --// wasnt queued
	self.waiting[key] = nil --// a slot only ever holds the player whose key points at it, take and add keep them in sync
	self.keys[player] = nil
end

function MatchQueue.take(self: MatchQueue, key: string): Player?
	local waiting = self.waiting[key]
	if not waiting then return nil end
	self.waiting[key] = nil
	self.keys[waiting] = nil --// the waiter isnt queued anymore so their reverse entry goes too
	return waiting
end

function MatchQueue.add(self: MatchQueue, player: Player, key: string)
	self.waiting[key] = player --// only reached when take found nobody, so this slot is always empty here
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
	values.BestStreak = math.max(values.BestStreak, values.Streak) --// best only moves up, so a streak that ended never lowers it
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
	local key = tostring(self.user_id)
	task.spawn(pcall, match_stats_store.UpdateAsync, match_stats_store, key, function() return values end) --// spawned so a slow datastore cant hold up the match result, pcall so a failed save doesnt error the thread
end

--// match, one per pair of players from the start till the result is decided

type MatchFields = {id: string, players: {Player}, start_time: number, min_duration: number, reports: {[Player]: MatchReport?}}

local Match = {}
Match.__index = Match
type Match = typeof(setmetatable({} :: MatchFields, Match))

function Match.new(id: string, first: Player, second: Player, chart: Chart): Match
	return setmetatable({
		id = id,
		players = {first, second},
		start_time = os.clock(), --// is_too_early measures against this
		min_duration = get_min_duration(chart),
		reports = {},
	}, Match)
end

function Match.has_reported(self: Match, player: Player): boolean
	return self.reports[player] ~= nil --// forfeits are reports too, so they count
end

function Match.is_too_early(self: Match): boolean
	return os.clock() - self.start_time < self.min_duration --// this stops instant fake results
end

function Match.submit(self: Match, player: Player, report: MatchReport)
	self.reports[player] = report --// callers check has_reported first so this never overwrites
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
	return true, nil --// nothing above returned so the scores are equal
end

--// party

type PartyFields = {
	id: string,
	owner: Player,
	members: {Player},
	side: Side,
	joinable: Joinable,
	win_condition: WinCondition,
	match_id: string?, --// missing while the party is open, when it fills this gets set and thats the lock
}

local Party = {}
Party.__index = Party
type Party = typeof(setmetatable({} :: PartyFields, Party))

function Party.new(owner: Player, side: Side, joinable: Joinable, win_condition: WinCondition): Party
	return setmetatable({
		id = http_service:GenerateGUID(false),
		owner = owner,
		members = {owner}, --// starts as just the owner, lock adds the joiner
		side = side,
		joinable = joinable,
		win_condition = win_condition,
	}, Party)
end

function Party.is_open_for(self: Party, viewer: Player): boolean
	return self.match_id == nil and self.joinable == "Everyone" and self.owner ~= viewer --// u never see ur own party as joinable, and a party whose owner left is already gone from parties
end

function Party.to_listing(self: Party): PartyListing
	return {
		Id = self.id,
		PartyName = `{self.owner.Name} Party`,
		Side = self.side,
		Joinable = self.joinable,
		WinCondition = self.win_condition,
		RankedBy = self.win_condition, --// the client reads both names so both stay
	}
end

function Party.lock(self: Party, joiner: Player, match_id: string)
	table.insert(self.members, joiner) --// order is [owner, joiner], resolve_party_pick reads the slots by number
	self.match_id = match_id --// this is the lock, from here is_open_for is false and the party leaves every list
end

--// state

type PartyPick = {party: Party, picks: {[Player]: SongPick}}

local batch_limiter = RateLimiter.new(max_batches_per_second) --// two limiters so press batches dont eat the menu action budget
local action_limiter = RateLimiter.new(max_actions_per_second)
local match_queue = MatchQueue.new()
local active_matches: {[Player]: Player?} = {} --// player -> opponent, who presses get sent to
local player_match: {[Player]: Match?} = {} --// only lasts till the result is decided, not the whole match
local parties: {[string]: Party} = {} --// party id -> party, every party list is built from this
local player_party_id: {[Player]: string} = {} --// always points at a party thats in parties, both get set and cleared together
local pick_states: {[string]: PartyPick} = {} --// match id -> song picks of a full party
local stats_cache: {[number]: Stats} = {} --// keyed by user id, same as the datastore key
local player_leaderstats: {[Player]: Leaderstats} = {}

--// messaging

local function send(player: Player, message: ServerMessage)
	pvp_remote:FireClient(player, message)
end

local function notify_left(player: Player) --// same OpponentLeft whether they left or their party fell apart
	if player.Parent then send(player, {a = "OpponentLeft"}) end --// the other side can be mid leave and firing at them would be pointless
end

--// stats

local function load_stats(user_id: number): Stats
	local cached = stats_cache[user_id]
	if cached then return cached end --// cache hit means no datastore call and no yield
	local success, data = pcall(match_stats_store.GetAsync, match_stats_store, tostring(user_id)) --// yields, so callers have to expect a pause on a cold cache
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
	leaderstats.Wins.Value = values.Wins --// IntValues replicate by themselves so the player list updates without a remote
	leaderstats.Losses.Value = values.Losses
	leaderstats.Streak.Value = values.Streak
end

--// save goes first so a player who just left still keeps their result, the rest is only for someone whos still here
local function commit_stats(player: Player, stats: Stats)
	stats:save()
	if not player.Parent then return end --// they already left, no1 to tell
	sync_leaderstats(player, stats.values)
	send(player, {a = "StatsUpdated", stats = stats.values}) --// leaderstats only has 3 of the 5 values so the full table goes over the remote
end

--// results

local function record_win(winner: Player, loser: Player)
	local winner_stats, loser_stats = load_stats(winner.UserId), load_stats(loser.UserId) --// both loaded before any edit so the result lands as one step
	winner_stats:add_win()
	loser_stats:add_loss()
	commit_stats(winner, winner_stats)
	commit_stats(loser, loser_stats)
end

local function record_draw(first: Player, second: Player)
	for _, player in {first, second} do --// both players get the same steps so its a loop
		local stats = load_stats(player.UserId)
		stats:add_draw()
		commit_stats(player, stats)
	end
end

local function try_resolve_match(match: Match)
	local done, winner = match:result()
	if not done then return end
	local first, second = match.players[1], match.players[2]
	player_match[first] = nil --// cleared before record_win cuz it can yield, so a late report finds no match and cant resolve it twice
	player_match[second] = nil
	if winner == nil then --// nil winner means draw
		record_draw(first, second)
	else
		record_win(winner, match:opponent_of(winner))
	end
end

local function forfeit_match(player: Player)
	local match = player_match[player]
	if not match or match:has_reported(player) then return end --// no match, or they already reported so leaving doesnt cost them
	match:submit(player, {score = 0, forfeited = true}) --// the flag decides the result, score never gets compared
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
	send(player, {
		a = "Matched",
		role = role,
		opponent = opponent.Name,
		song = choice.song,
		difficulty = choice.difficulty,
		countdown = countdown_seconds,
		matchId = match_id,
	})
end

--// queue and party pick both end up here so matches get set up the same either way
local function start_match(match_id: string, first: Player, first_role: Role, second: Player, choice: SongChoice)
	local match = Match.new(match_id, first, second, choice.chart) --// one Match object for both players so the result lands in one place
	player_match[first] = match
	player_match[second] = match
	active_matches[first] = second
	active_matches[second] = first --// both directions so each side knows who to relay presses to
	announce_match(first, first_role, second, choice, match_id)
	announce_match(second, opposite_role(first_role), first, choice, match_id) --// second gets the flipped role so the two clients never both think theyre the Player
end

--// parties

--// if ur already queued, matched or in a party u cant start another one
local function is_busy(player: Player): boolean
	return active_matches[player] ~= nil or player_match[player] ~= nil or player_party_id[player] ~= nil
end

local function send_party_list(player: Player)
	local list: {PartyListing} = {}
	for _, party in parties do
		if party:is_open_for(player) then table.insert(list, party:to_listing()) end --// built per player cuz is_open_for leaves out their own party
	end
	send(player, {a = "PartyListUpdated", parties = list})
end

local function broadcast_party_list()
	for _, player in players:GetPlayers() do
		send_party_list(player)
	end
end

local function cleanup_party_state(player: Player)
	local party_id = player_party_id[player]
	if not party_id then return end --// not in a party
	local party = parties[party_id]
	player_party_id[player] = nil
	parties[party_id] = nil
	local match_id = party.match_id
	if match_id == nil then --// no match id means the party never filled
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
	if pick and chart then return {song = pick.song, difficulty = pick.difficulty, chart = chart} end --// both checked together so strict mode knows neither is nil here
	return get_random_song_pick()
end

local function resolve_party_pick(match_id: string)
	local pick_state = pick_states[match_id]
	if not pick_state then return end --// someone left before the timer ran and cleanup already got it
	pick_states[match_id] = nil --// taken out first so this party cant resolve twice
	local party = pick_state.party
	parties[party.id] = nil
	local owner, joiner = party.members[1], party.members[2] --// lock put them in this order
	player_party_id[owner] = nil --// party is done from here on whether a match starts or not
	player_party_id[joiner] = nil
	local chosen = party.members[math.random(1, 2)] --// only one of the two picks gets played
	local choice = choose_party_song(pick_state.picks[chosen]) --// the chosen one may never have picked, choose_party_song then goes random
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
	if player_match[player] or active_matches[player] then return end --// already in a match, dying shouldnt touch anything
	match_queue:clear(player)
	local party_id = player_party_id[player]
	if party_id and parties[party_id].match_id == nil then cleanup_party_state(player) end --// full party is already in its pick window so leave it alone
end

local function hook_character(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid? --// timeout cuz a custom rig might never get one
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
	local chart = get_pvp_chart(song, difficulty) --// checks song, difficulty and the solo rule in one go
	if not chart then return end
	match_queue:clear(player) --// one slot per player, and this frees their old slot so they cant match w themselves
	local key = make_queue_key(song, difficulty)
	local waiting = match_queue:take(key) --// someone already waiting on this exact song + difficulty
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
	local score = read_number(payload.score)
	if not score then return end
	local match = player_match[player]
	if not match or match.id ~= read_string(payload.matchId) then return end --// has to be the match theyre actually in and not decided yet
	if match:has_reported(player) then return end --// first report counts, no resending
	if match:is_too_early() then return end --// too early to be a real finish
	match:submit(player, {score = math.clamp(score, 0, Config.MaxScore), forfeited = false}) --// clamped cuz the client picks the number, this only limits how far off it can be
	try_resolve_match(match)
end

handlers.CreateParty = function(player: Player, payload: Payload)
	if is_busy(player) then return end
	local side: Side? = valid_sides[read_key(payload.side)] --// a non string comes out of read_key as an empty string and misses the whitelist
	local joinable: Joinable? = valid_joinable[read_key(payload.joinable)]
	local win_condition: WinCondition? = valid_win_conditions[read_key(payload.winCondition)]
	if not (side and joinable and win_condition) then return end --// the whitelists double as type checks
	local party = Party.new(player, side, joinable, win_condition)
	parties[party.id] = party
	player_party_id[player] = party.id
	if joinable == "Everyone" then broadcast_party_list() end --// a Nobody party never shows up in any list so theres nothing to refresh
end

handlers.JoinParty = function(player: Player, payload: Payload)
	if is_busy(player) then return end
	local party_id = read_string(payload.partyId)
	local party = if party_id then parties[party_id] else nil
	if not party or not party:is_open_for(player) then return end --// is_open_for also catches a party that filled a moment ago
	local match_id = http_service:GenerateGUID(false)
	party:lock(player, match_id)
	player_party_id[player] = party.id
	pick_states[match_id] = {party = party, picks = {}} --// picks fill in as PickSong comes in, resolve_party_pick reads them when the timer ends
	broadcast_party_list() --// locked now, so it drops out of everyone elses list
	local owner_role: Role = role_for_side(party.side)
	announce_party_ready(party.owner, owner_role, player, match_id)
	announce_party_ready(player, opposite_role(owner_role), party.owner, match_id)
	task.delay(pick_seconds, resolve_party_pick, match_id) --// pick window ends here even if no1 picked
end

handlers.LeaveParty = cleanup_party_state --// already takes just the player, extra payload arg gets ignored
handlers.RequestPartyList = send_party_list

handlers.PickSong = function(player: Player, payload: Payload)
	local match_id = read_string(payload.matchId)
	local pick_state = if match_id then pick_states[match_id] else nil
	if not pick_state or not table.find(pick_state.party.members, player) then return end --// only the two ppl in that party can pick
	local song, difficulty = read_string(payload.song), read_string(payload.difficulty)
	if not song or not difficulty or not get_pvp_chart(song, difficulty) then return end --// same playability check the queue uses, so a picked song always has a chart
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
	local handler = handlers[read_key(message.a)] --// a non string action becomes "" and misses like any unknown one
	if not handler or action_limiter:is_limited(player) then return end --// only real actions eat into the rate limit
	handler(player, message)
end)

press_relay.OnServerEvent:Connect(function(player: Player, events: unknown)
	if typeof(events) ~= "table" then return end
	local list = events :: {unknown}
	if #list > max_events_per_batch then return end
	if batch_limiter:is_limited(player) then return end --// after the size check so oversized junk doesnt eat the budget
	local opponent = active_matches[player]
	if not opponent or not opponent.Parent then return end --// no match, or the opponent is mid leave
	local sanitized: {PressEvent} = {}
	for _, event in ipairs(list) do --// ipairs only goes thru the array part, same part the size cap counted
		local press = sanitize_press(event)
		if press then table.insert(sanitized, press) end
	end
	if #sanitized == 0 then return end --// a batch of only junk isnt worth a remote call
	press_relay:FireClient(opponent, sanitized) --// one remote call per batch, not one per press
end)

pvp_stats_function.OnServerInvoke = function(player: Player): PlayerStats
	return load_stats(player.UserId).values --// plain values table, the same one StatsUpdated sends
end

players.PlayerAdded:Connect(function(player: Player)
	create_leaderstats(player)
	task.spawn(function() sync_leaderstats(player, load_stats(player.UserId).values) end) --// spawned so the datastore read doesnt hold up the character hook below
	player.CharacterAdded:Connect(function(character) hook_character(player, character) end) --// every respawn fires this again and gets its own Died hook
end)

players.PlayerRemoving:Connect(function(player: Player)
	batch_limiter:forget(player) --// limiters keep a table per player so leavers have to be dropped
	action_limiter:forget(player)
	player_leaderstats[player] = nil --// dropped before forfeit_match so a result that lands now skips leaderstats thats going away
	match_queue:clear(player)
	cleanup_party_state(player) --// an open party just disappears, a full one tells the other member
	forfeit_match(player) --// leaving mid match is a loss unless they already reported
	end_match(player)
	stats_cache[player.UserId] = nil --// last on purpose, forfeit_match needs this cached copy or it would re read the store and put a stale entry back
end)
