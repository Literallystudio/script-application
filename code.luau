--// Connected Discord-GitHub 
--!strict

--// services

local replicated_storage = game:GetService("ReplicatedStorage")
local players = game:GetService("Players")
local http_service = game:GetService("HttpService")
local data_store_service = game:GetService("DataStoreService")

--// modules

local SongCatalog = require(replicated_storage.ClientModules.SongCatalog) --// both are in repstorage so the client can read the same catalog and config
local Config = require(replicated_storage.ClientModules.Config)

--// remotes

local function make_remote(class_name: string, name: string): any
	local remote = Instance.new(class_name)
	remote.Name = name
	remote.Parent = replicated_storage --// made here so i dont gotta pre build them in the place file
	return remote
end

local press_relay: RemoteEvent = make_remote("RemoteEvent", "PressRelay") --// note presses, just gets sent straight to the opponent
local pvp_remote: RemoteEvent = make_remote("RemoteEvent", "PvPRemote") --// queue, party and result stuff all comes thru here, payload.a says which one
local pvp_stats_function: RemoteFunction = make_remote("RemoteFunction", "PvPStatsFunction")

--// settings

local max_events_per_batch = 40
local max_batches_per_second = 30 --// presses spam a lot so batches get a way higher cap than menu stuff
local max_actions_per_second = 5
local countdown_seconds = 3
local min_match_duration_seconds = 5
local pick_seconds = 15 --// how long both ppl have to send PickSong after the party fills

local valid_directions = {UP = true, DOWN = true, LEFT = true, RIGHT = true}
local valid_sides = {Left = true, Right = true}
local valid_joinable = {Everyone = true, Nobody = true}
local valid_win_conditions = {Score = true, Accuracy = true, Misses = true}

--// types

type RateWindow = {count: number, window_start: number}
type MatchReport = {score: number, accuracy: number, forfeited: boolean}

type MatchRecord = {
	id: string,
	players: {Player},
	start_time: number,
	min_duration: number,
	reports: {[Player]: MatchReport},
}

type PartyRecord = {
	id: string,
	owner: Player,
	members: {Player},
	side: string,
	joinable: string,
	win_condition: string,
	match_id: string?, --// nil while the party is open, when it fills this gets set and thats the lock
}

type SongPick = {song: string, difficulty: string}

type PartyPick = {
	record: PartyRecord,
	picks: {[Player]: SongPick},
}

type PlayerStats = {Wins: number, Losses: number, Draws: number, Streak: number, BestStreak: number} --// these keys are whats saved in the datastore so the casing stays
type Leaderstats = {Wins: IntValue, Losses: IntValue, Streak: IntValue}

--// state

local batch_counts: {[Player]: RateWindow} = {}
local action_counts: {[Player]: RateWindow} = {}
local queue: {[string]: Player} = {} --// song / difficulty -> the one player waiting on it
local player_queue_key: {[Player]: string} = {} --// reverse lookup so someone leaving can find their slot
local active_matches: {[Player]: Player} = {} --// player -> opponent, who presses get sent to
local player_match: {[Player]: MatchRecord} = {} --// only lasts till the result is decided, not the whole match
local parties: {[string]: PartyRecord} = {}
local player_party_id: {[Player]: string} = {}
local pick_states: {[string]: PartyPick} = {} --// match id -> song picks of a full party
local stats_cache: {[number]: PlayerStats} = {}
local player_leaderstats: {[Player]: Leaderstats} = {}
local match_stats_store = data_store_service:GetDataStore("PvPStats_v1")

--// stats

local function as_number(value: any): number
	return if typeof(value) == "number" then value else 0 --// saved data can be missing stuff or just be junk
end

local function load_stats(user_id: number): PlayerStats
	local cached = stats_cache[user_id]
	if cached then return cached end
	local success, data = pcall(match_stats_store.GetAsync, match_stats_store, tostring(user_id))
	local saved: any = if success and typeof(data) == "table" then data else {} --// failed read and brand new player both just start at 0
	local stats: PlayerStats = {
		Wins = as_number(saved.Wins),
		Losses = as_number(saved.Losses),
		Draws = as_number(saved.Draws),
		Streak = as_number(saved.Streak),
		BestStreak = as_number(saved.BestStreak),
	}
	stats_cache[user_id] = stats --// this exact table is what results edit + save so theres only ever one copy
	return stats
end

local function save_stats(user_id: number, stats: PlayerStats)
	task.spawn(pcall, match_stats_store.UpdateAsync, match_stats_store, tostring(user_id), function() return stats end) --// spawned so a slow datastore cant hold up the match result
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

local function sync_leaderstats(player: Player, stats: PlayerStats)
	local leaderstats = player_leaderstats[player]
	if not leaderstats then return end --// gets removed on leave, and a stats load can finish after that
	leaderstats.Wins.Value = stats.Wins
	leaderstats.Losses.Value = stats.Losses
	leaderstats.Streak.Value = stats.Streak
end

local function push_stats(player: Player, stats: PlayerStats)
	if not player.Parent then return end --// they already left, no1 to tell
	sync_leaderstats(player, stats)
	pvp_remote:FireClient(player, {a = "StatsUpdated", stats = stats})
end

--// limits and queue

local function is_rate_limited(windows: {[Player]: RateWindow}, player: Player, max_per_second: number): boolean
	local now = os.clock()
	local window = windows[player]
	if not window or now - window.window_start >= 1 then
		windows[player] = {count = 1, window_start = now} --// fixed 1 sec window, one small table per player instead of a list of timestamps
		return false
	end
	window.count += 1
	return window.count > max_per_second
end

local function make_queue_key(song: string, difficulty: string): string
	return string.lower(song) .. "|" .. string.lower(difficulty) --// lowercased so diff casing cant put ppl in separate queues
end

local function clear_queue(player: Player)
	local key = player_queue_key[player]
	if key and queue[key] == player then queue[key] = nil end --// the slot might be someone elses by now
	player_queue_key[player] = nil
end

local function end_match(player: Player)
	local opponent = active_matches[player]
	if not opponent then return end
	active_matches[player] = nil
	active_matches[opponent] = nil --// both get cleared together so presses stop relaying both ways
	if opponent.Parent then pvp_remote:FireClient(opponent, {a = "OpponentLeft"}) end
end

--// charts

local function load_charts(song: string): {[string]: any}?
	local song_module = SongCatalog.FindSongModule(song)
	if not song_module then return nil end
	local success, data = pcall(require, song_module) --// pcall so one broken song module doesnt error the whole handler
	if not success or typeof(data) ~= "table" or typeof(data.Charts) ~= "table" then return nil end
	return data.Charts
end

--// one spot decides whats playable so queue, party picks and the random fallback cant disagree
local function get_pvp_chart(song: any, difficulty: any): {any}?
	if typeof(song) ~= "string" or typeof(difficulty) ~= "string" then return nil end --// this is client input, string.lower would just take a number lol
	local charts = load_charts(song)
	if not charts then return nil end
	for chart_difficulty, chart in charts do
		if string.lower(chart_difficulty) == string.lower(difficulty) then --// clients can send any casing
			return if SongCatalog.IsSoloOnly(song, difficulty) then nil else chart
		end
	end
	return nil
end

local function get_random_song_pick(): (string?, string?, {any}?)
	local candidates: {string} = {}
	for _, song_module in ipairs(SongCatalog.Get()) do
		for _, song in ipairs(song_module.Songs) do
			if not SongCatalog.HasAnySoloRestriction(song) then table.insert(candidates, song) end
		end
	end
	if #candidates == 0 then return nil, nil, nil end
	local song = candidates[math.random(1, #candidates)]
	local charts = load_charts(song)
	if not charts then return nil, nil, nil end
	local difficulties: {string} = {}
	for difficulty in charts do
		if not SongCatalog.IsSoloOnly(song, difficulty) then table.insert(difficulties, difficulty) end
	end
	if #difficulties == 0 then return nil, nil, nil end
	local difficulty = difficulties[math.random(1, #difficulties)]
	return song, difficulty, get_pvp_chart(song, difficulty)
end

local function get_min_duration(chart: {any}): number
	local last_note_end = 0
	for _, note in ipairs(chart) do
		last_note_end = math.max(last_note_end, note.t + (if typeof(note.d) == "number" then note.d else 0)) --// d is an optional length on top of the note time
	end
	return math.max(last_note_end / 1000 * 0.85, min_match_duration_seconds) --// note times are in ms, floor is 85% of the last note time but never under the min
end

--// results

local function record_win(winner: Player, loser: Player)
	local winner_stats, loser_stats = load_stats(winner.UserId), load_stats(loser.UserId) --// these can yield if the cache is cold
	winner_stats.Wins += 1
	winner_stats.Streak += 1
	winner_stats.BestStreak = math.max(winner_stats.BestStreak, winner_stats.Streak)
	loser_stats.Losses += 1
	loser_stats.Streak = 0 --// loss resets the streak, draw doesnt touch it
	save_stats(winner.UserId, winner_stats)
	save_stats(loser.UserId, loser_stats)
	push_stats(winner, winner_stats)
	push_stats(loser, loser_stats)
end

local function record_draw(first: Player, second: Player)
	for _, player in {first, second} do
		local stats = load_stats(player.UserId)
		stats.Draws += 1
		save_stats(player.UserId, stats)
		push_stats(player, stats)
	end
end

local function pick_winner(first: Player, second: Player, first_report: MatchReport, second_report: MatchReport): Player?
	if first_report.forfeited and second_report.forfeited then return nil end --// both left so no one wins
	if first_report.forfeited then return second end --// whoever forfeited loses no matter what the scores were
	if second_report.forfeited then return first end
	if first_report.score > second_report.score then return first end --// > both ways so equal scores fall thru to a draw
	if second_report.score > first_report.score then return second end
	return nil
end

local function try_resolve_match(record: MatchRecord)
	local first, second = record.players[1], record.players[2]
	local first_report, second_report = record.reports[first], record.reports[second]
	if not first_report or not second_report then return end --// still waiting on the other player
	player_match[first] = nil --// cleared before record_win cuz it can yield, so a late report finds no match and cant resolve it twice
	player_match[second] = nil
	local winner = pick_winner(first, second, first_report, second_report)
	if winner == nil then
		record_draw(first, second)
	else
		record_win(winner, if winner == first then second else first)
	end
end

local function forfeit_match(player: Player)
	local record = player_match[player]
	if not record or record.reports[player] then return end --// no match, or they already reported so leaving doesnt cost them
	record.reports[player] = {score = 0, accuracy = 0, forfeited = true} --// the flag decides the result, score never gets compared
	try_resolve_match(record)
end

--// matches and parties

local function role_for_side(side: string): string
	return if side == "Right" then "Player" else "Opponent"
end

local function opposite_role(role: string): string
	return if role == "Player" then "Opponent" else "Player"
end

local function announce_match(player: Player, role: string, opponent: Player, song: string, difficulty: string, match_id: string)
	pvp_remote:FireClient(player, {a = "Matched", role = role, opponent = opponent.Name, song = song, difficulty = difficulty, countdown = countdown_seconds, matchId = match_id})
end

--// queue and party pick both end up here so matches get set up the same either way
local function start_match(match_id: string, first: Player, first_role: string, second: Player, song: string, difficulty: string, chart: {any})
	local record: MatchRecord = {id = match_id, players = {first, second}, start_time = os.clock(), min_duration = get_min_duration(chart), reports = {}}
	player_match[first] = record
	player_match[second] = record
	active_matches[first] = second
	active_matches[second] = first
	announce_match(first, first_role, second, song, difficulty, match_id)
	announce_match(second, opposite_role(first_role), first, song, difficulty, match_id)
end

--// if ur already queued, matched or in a party u cant start another one
local function is_busy(player: Player): boolean
	return active_matches[player] ~= nil or player_match[player] ~= nil or player_party_id[player] ~= nil
end

local function is_open_for(record: PartyRecord, viewer: Player): boolean
	return record.match_id == nil and record.joinable == "Everyone" and record.owner.Parent ~= nil and record.owner ~= viewer --// u never see ur own party as joinable
end

local function build_open_party_list(viewer: Player): {any}
	local list = {}
	for _, record in parties do
		if is_open_for(record, viewer) then
			table.insert(list, {
				Id = record.id,
				PartyName = `{record.owner.Name} Party`,
				Side = record.side,
				Joinable = record.joinable,
				WinCondition = record.win_condition,
				RankedBy = record.win_condition,
			})
		end
	end
	return list
end

local function broadcast_party_list()
	for _, player in players:GetPlayers() do
		pvp_remote:FireClient(player, {a = "PartyListUpdated", parties = build_open_party_list(player)}) --// built per player cuz everyone has their own party left out
	end
end

local function cleanup_party_state(player: Player)
	local party_id = player_party_id[player]
	local record = if party_id then parties[party_id] else nil
	player_party_id[player] = nil
	if not record then return end
	parties[record.id] = nil
	local match_id = record.match_id
	if not match_id then
		broadcast_party_list() --// an open party is gone so every list is outdated
		return
	end
	pick_states[match_id] = nil --// the pick timer still fires later but theres nothing there
	for _, member in record.members do
		if member == player then continue end
		player_party_id[member] = nil
		if member.Parent then pvp_remote:FireClient(member, {a = "OpponentLeft"}) end
	end
end

--// picked song only counts if its still playable (match needs its chart anyway), otherwise random
local function choose_party_song(pick: SongPick?): (string?, string?, {any}?)
	if pick then
		local chart = get_pvp_chart(pick.song, pick.difficulty)
		if chart then return pick.song, pick.difficulty, chart end
	end
	return get_random_song_pick()
end

local function resolve_party_pick(match_id: string)
	local pick_state = pick_states[match_id]
	if not pick_state then return end --// someone left before the timer ran and cleanup already got it
	pick_states[match_id] = nil
	local record = pick_state.record
	parties[record.id] = nil
	local owner, joiner = record.members[1], record.members[2]
	player_party_id[owner] = nil --// party is done from here on whether a match starts or not
	player_party_id[joiner] = nil
	if not owner.Parent or not joiner.Parent then return end
	local chosen = record.members[math.random(1, 2)] --// only one of the two picks gets played
	local song, difficulty, chart = choose_party_song(pick_state.picks[chosen])
	if not song or not difficulty or not chart then
		for _, member in {owner, joiner} do
			if member.Parent then pvp_remote:FireClient(member, {a = "OpponentLeft"}) end --// nothing playable at all so both get the same OpponentLeft a leaver would cause
		end
		return
	end
	start_match(match_id, owner, role_for_side(record.side), joiner, song, difficulty, chart)
end

local function announce_party_ready(player: Player, role: string, opponent: Player, match_id: string)
	pvp_remote:FireClient(player, {a = "PartyReady", role = role, opponent = opponent.Name, matchId = match_id, pickSeconds = pick_seconds})
end

--// dying only backs u out of stuff that isnt locked in yet
local function handle_reset(player: Player)
	if player_match[player] or active_matches[player] then return end
	clear_queue(player)
	local party_id = player_party_id[player]
	local record = if party_id then parties[party_id] else nil
	if record and record.match_id == nil then cleanup_party_state(player) end --// full party is already in its pick window so leave it alone
end

local function hook_character(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then return end
	humanoid.Died:Connect(function() handle_reset(player) end)
end

--// actions, every handler gets the player + raw payload, anything in it can be junk cuz it came from a client
--// party and match ids arent typeof checked, a wrong type id never indexes or equals anything real anyway

local handlers: {[string]: (Player, any) -> ()} = {}

handlers.Queue = function(player: Player, payload: any)
	if active_matches[player] then return end
	local song, difficulty = payload.song, payload.difficulty
	local chart = get_pvp_chart(song, difficulty)
	if not chart then return end
	clear_queue(player) --// one slot per player, and this frees their old slot so they cant match w themselves
	local key = make_queue_key(song, difficulty)
	local waiting = queue[key]
	if waiting and waiting.Parent then
		queue[key] = nil
		player_queue_key[waiting] = nil
		start_match(http_service:GenerateGUID(false), waiting, "Player", player, song, difficulty, chart) --// whoever waited first is the Player
	else
		queue[key] = player --// also covers a waiter that left w/o clearing, their old entry just gets replaced
		player_queue_key[player] = key
		pvp_remote:FireClient(player, {a = "Waiting", song = song, difficulty = difficulty})
	end
end

handlers.Cancel = function(player: Player)
	clear_queue(player)
end

handlers.EndMatch = function(player: Player)
	forfeit_match(player) --// records the loss first, then end_match unlinks them and tells the opponent
	end_match(player)
end

handlers.ReportResult = function(player: Player, payload: any)
	local score, accuracy = payload.score, payload.accuracy
	if typeof(score) ~= "number" or typeof(accuracy) ~= "number" then return end
	local record = player_match[player]
	if not record or record.id ~= payload.matchId then return end --// has to be the match theyre actually in and not decided yet
	if record.reports[player] then return end --// first report counts, no resending
	if os.clock() - record.start_time < record.min_duration then return end --// too early to be a real finish, this stops instant fake results
	record.reports[player] = {score = math.clamp(score, 0, Config.MaxScore), accuracy = math.clamp(accuracy, 0, 100), forfeited = false}
	try_resolve_match(record)
end

handlers.CreateParty = function(player: Player, payload: any)
	if is_busy(player) then return end
	local side, joinable, win_condition = payload.side, payload.joinable, payload.winCondition
	if not (valid_sides[side] and valid_joinable[joinable] and valid_win_conditions[win_condition]) then return end --// the whitelists double as type checks
	local party_id = http_service:GenerateGUID(false)
	parties[party_id] = {id = party_id, owner = player, members = {player}, side = side, joinable = joinable, win_condition = win_condition}
	player_party_id[player] = party_id
	if joinable == "Everyone" then broadcast_party_list() end
end

handlers.JoinParty = function(player: Player, payload: any)
	if is_busy(player) then return end
	local record = parties[payload.partyId]
	if not record or not is_open_for(record, player) then return end
	local match_id = http_service:GenerateGUID(false)
	table.insert(record.members, player)
	record.match_id = match_id --// this is the lock, from here is_open_for is false and the party leaves every list
	player_party_id[player] = record.id
	pick_states[match_id] = {record = record, picks = {}}
	broadcast_party_list()
	local owner_role = role_for_side(record.side)
	announce_party_ready(record.owner, owner_role, player, match_id)
	announce_party_ready(player, opposite_role(owner_role), record.owner, match_id)
	task.delay(pick_seconds, resolve_party_pick, match_id) --// pick window ends here even if no1 picked
end

handlers.LeaveParty = function(player: Player)
	cleanup_party_state(player)
end

handlers.RequestPartyList = function(player: Player)
	pvp_remote:FireClient(player, {a = "PartyListUpdated", parties = build_open_party_list(player)})
end

handlers.PickSong = function(player: Player, payload: any)
	local pick_state = pick_states[payload.matchId]
	if not pick_state or not table.find(pick_state.record.members, player) then return end
	if not get_pvp_chart(payload.song, payload.difficulty) then return end
	pick_state.picks[player] = {song = payload.song, difficulty = payload.difficulty} --// last pick wins, and only one of the two picks gets used later
end

--// connections

pvp_remote.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" or typeof(payload.a) ~= "string" then return end
	if is_rate_limited(action_counts, player, max_actions_per_second) then return end
	local handler = handlers[payload.a]
	if handler then handler(player, payload) end
end)

press_relay.OnServerEvent:Connect(function(player: Player, events: any)
	if typeof(events) ~= "table" or #events > max_events_per_batch then return end
	if is_rate_limited(batch_counts, player, max_batches_per_second) then return end
	local opponent = active_matches[player]
	if not opponent or not opponent.Parent then return end
	local sanitized = {}
	for _, event: any in ipairs(events) do --// ipairs only goes thru the array part, same part the size cap counted
		if typeof(event) == "table" and (event.t == "press" or event.t == "release") and valid_directions[event.d] then
			table.insert(sanitized, {t = event.t, d = event.d}) --// rebuilt w just t and d so a client cant send extra fields to the opponent
		end
	end
	if #sanitized == 0 then return end
	press_relay:FireClient(opponent, sanitized)
end)

pvp_stats_function.OnServerInvoke = function(player: Player)
	return load_stats(player.UserId)
end

players.PlayerAdded:Connect(function(player: Player)
	create_leaderstats(player)
	task.spawn(function() sync_leaderstats(player, load_stats(player.UserId)) end) --// spawned so the datastore read doesnt hold up the character hooks below
	player.CharacterAdded:Connect(function(character) hook_character(player, character) end)
	if player.Character then hook_character(player, player.Character) end
end)

players.PlayerRemoving:Connect(function(player: Player)
	batch_counts[player] = nil
	action_counts[player] = nil
	stats_cache[player.UserId] = nil
	player_leaderstats[player] = nil
	clear_queue(player)
	cleanup_party_state(player)
	forfeit_match(player)
	end_match(player)
end)
