--// Connected Discord-GitHub

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Access = ReplicatedStorage:WaitForChild("Access")
local Objects = Access.Value or Access.Changed:Wait() --// value can be nil on the client until the ObjectValue replicates

local Config = require(Objects:WaitForChild("SkillTreeConfig").Value)
local Signal = require(Objects:WaitForChild("SkillTreeSignal").Value) --// the class fires signals so it never needs to know about ui or saving

local Codes = Config.Codes
local States = Config.States
local EMPTY = table.freeze({}) --// shared stand-in for missing optional tables, "x or EMPTY" allocates nothing

--// one tree object is shared by all players. player data only lives in the raw table the caller passes in
local SkillTreeClass = {}
SkillTreeClass.__index = SkillTreeClass

--// helpers
local function deepFreeze(t) --// table.freeze is shallow
	if table.isfrozen(t) then --// also the visited check, so shared sub tables are skipped
		return
	end
	table.freeze(t) --// frozen before the walk so a self-referencing table stops at the check above
	for _, v in t do
		if type(v) == "table" then
			deepFreeze(v)
		end
	end
end

local function toSet(raw) --// array to set, so "is this parent owned" is one index and not a table.find scan
	local set = {}
	for _, id in raw.UnlockedSkills do
		set[id] = true
	end
	return set
end

local function isNumber(value) --// nan and inf both pass type() == "number" but break the layout math
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function assertOptionalNumber(value, label, id)
	assert(value == nil or isNumber(value), label .. " must be a number (skill " .. id .. ")")
end

local function validatePrevious(tree, id, previous) --// checks ids against the raw tree, so table order doesnt matter
	assert(type(previous) == "table", "Previous must be a table (skill " .. id .. ")")
	for _, prevId in previous do
		assert(type(prevId) == "number", "Previous ids must be numbers (skill " .. id .. ")")
		assert(prevId ~= id, "skill cannot require itself (skill " .. id .. ")")
		assert(tree[prevId], "unknown Previous " .. tostring(prevId) .. " (skill " .. id .. ")") --// this is what makes tree[prevId] safe everywhere else
	end
end

local function validateSkill(tree, id, skill)
	assert(type(id) == "number", "skill ids must be numbers") --// ids get sorted in the layout, a string would error in table.sort
	assert(type(skill) == "table", "skill must be a table (skill " .. id .. ")")
	assert(Config.IsCount(skill.SkillCost), "SkillCost must be a non-negative integer (skill " .. id .. ")") --// same rule GivePoints uses
	assert(type(skill.info) == "table", "missing info (skill " .. id .. ")") --// never read here, just guaranteed for whatever consumes the skill
	assert(skill.RequireAll == nil or type(skill.RequireAll) == "boolean", "RequireAll must be a boolean (skill " .. id .. ")") --// DefaultReach checks == true, so the string "true" would act as false
	assertOptionalNumber(skill.OnGridLine, "OnGridLine", id)
	assertOptionalNumber(skill.OnGridColumn, "OnGridColumn", id)
	local align = skill.AlignTo or EMPTY
	assert(type(align) == "table", "AlignTo must be a table (skill " .. id .. ")")
	assertOptionalNumber(align.OnGridLine, "AlignTo.OnGridLine", id)
	assertOptionalNumber(align.OnGridColumn, "AlignTo.OnGridColumn", id)
	if skill.Previous then
		validatePrevious(tree, id, skill.Previous)
	end
end

--// dfs with 3 states, reaching a skill that is still on the current path is a back edge, so a cycle
local function hasCycle(tree)
	local state = {} --// nil = unseen, 1 = on the path, 2 = done
	local function visit(id)
		if state[id] then --// a done skill is just a parent shared by several children, only 1 is a loop
			return state[id] == 1
		end
		state[id] = 1
		for _, prevId in tree[id].Previous or EMPTY do --// ids are valid by now, SetSkillTree validates before calling this
			if visit(prevId) then
				return true
			end
		end
		state[id] = 2
		return false
	end
	for id in tree do --// tree can be disconnected, so every skill is tried as a start
		if visit(id) then
			return true
		end
	end
	return false
end

local function computeDepths(tree) --// longest path from a root, memoised
	local depth = {}
	local function visit(id) --// no cycle guard, SetSkillTree rejects cycles first
		if depth[id] then
			return depth[id]
		end
		local d = 1
		for _, prevId in tree[id].Previous or EMPTY do
			d = math.max(d, visit(prevId) + 1) --// max over all parents so a skill never sits left of one of its parents
		end
		depth[id] = d
		return d
	end
	for id in tree do
		visit(id)
	end
	return depth
end

local function hasPrevious(skill) --// Previous = {} counts as a root too
	return skill.Previous ~= nil and #skill.Previous > 0
end

local function canReach(self, player, unlocked, skillId)
	local ok, result = pcall(self._reach, self, skillId, unlocked, player) --// _reach is a plain function stored on the instance, so self is passed by hand
	return ok and result == true --// fails closed: an error or a truthy non boolean never turns into an unlock
end

--// reach and constructor

--// public so a custom handler can wrap it. handlers get (tree, skillId, unlocked, player) and return true/false
function SkillTreeClass.DefaultReach(tree, skillId, unlocked, player)
	local skill = tree:GetSkill(skillId)
	if not skill then
		return false
	end
	if not hasPrevious(skill) then
		return true --// roots are always reachable, otherwise nothing could be unlocked first
	end
	local needAll = skill.RequireAll == true --// AND (every parent) or OR (any parent)
	for _, prevId in skill.Previous do
		if needAll and not unlocked[prevId] then
			return false
		end
		if not needAll and unlocked[prevId] then
			return true
		end
	end
	return needAll --// nothing decided early: AND had every parent (true), OR had none (false)
end

function SkillTreeClass.new(treeId: string) --// dot call, there is no instance yet
	assert(type(treeId) == "string" and treeId ~= "", "treeId must be a non-empty string")
	--// _tree, _layout, _otherReq, _uiGen, _hover and _click are set by the setters. the getters check _tree (and BuildUI _uiGen) before use
	return setmetatable({
		Id = treeId, --// goes into the ui payload as TreeId
		SkillUnlocked = Signal.new(),
		SkillsReset = Signal.new(),
		_reach = SkillTreeClass.DefaultReach, --// per instance, so one tree can swap its rule without touching the class
	}, SkillTreeClass)
end

function SkillTreeClass:SetSkillTree(tree)
	for id, skill in tree do --// validate everything before touching self, so a failed assert leaves the old tree and layout in place
		validateSkill(tree, id, skill)
	end
	assert(not hasCycle(tree), "skill tree contains a cycle") --// after the loop, hasCycle relies on the Previous ids being proven real
	deepFreeze(tree) --// GetSkills and the ui payload return this exact table. also freezes the callers table
	self._tree = tree
	self._layout = nil --// cached layout belongs to the old tree
end

function SkillTreeClass:HasSkillTree(): boolean
	return self._tree ~= nil
end

function SkillTreeClass:GetSkill(skillId)
	if type(skillId) ~= "number" or not self._tree then --// ids can come from player input
		return nil
	end
	return self._tree[skillId]
end

function SkillTreeClass:GetSkills() --// safe to hand out, its frozen
	return self._tree
end

function SkillTreeClass:SetSkillTreeReachHandler(reachHandler, otherUnlockingRequirements)
	if reachHandler then --// nil never wipes what was set, so either arg can be set alone
		self._reach = reachHandler --// no validation, canReach pcalls it
	end
	if otherUnlockingRequirements then
		self._otherReq = otherUnlockingRequirements
	end
end

function SkillTreeClass:SetUIGenerationHandler(handler)
	self._uiGen = handler
end

function SkillTreeClass:SetSkillTreeUIHandlers(mouseHovered, mouseClicked) --// only stored, the class never calls them
	self._hover = mouseHovered
	self._click = mouseClicked
end

function SkillTreeClass:GetUIHandlers()
	return self._hover, self._click
end

--// state and unlocking
function SkillTreeClass:IsUnlocked(raw, skillId): boolean --// linear scan is fine for one skill, bulk callers use toSet
	return table.find(raw.UnlockedSkills, skillId) ~= nil
end

function SkillTreeClass:IsInReach(player, raw, skillId): boolean --// builds a set per call, GetStates builds one for all skills
	return canReach(self, player, toSet(raw), skillId)
end

function SkillTreeClass:CheckRequirements(player, skillId): boolean
	local skill = self:GetSkill(skillId)
	if not skill then
		return false
	end
	local fn = skill.OtherUnlockingRequirements or self._otherReq --// the skills own rule replaces the global one, they never both run
	if not fn then
		return true
	end
	local ok, result = pcall(fn, player, skill, skillId) --// fn comes from outside (quests, level gates), an error in it must not break unlocking
	return ok and result == true
end

--// state is graph position only. points and OtherUnlockingRequirements are left to CheckUnlock
function SkillTreeClass:GetState(player, raw, skillId)
	if self:IsUnlocked(raw, skillId) then --// owned first, so an owned skill never shows as unlockable
		return States.Unlocked
	end
	if self:IsInReach(player, raw, skillId) then
		return States.Unlockable
	end
	return States.Locked
end

function SkillTreeClass:GetStates(player, raw) --// bulk GetState for BuildUI
	if not self._tree then
		return {}
	end
	local unlocked = toSet(raw) --// built once, GetState per skill would rebuild it every time
	local states = {}
	for id in self._tree do
		if unlocked[id] then
			states[id] = States.Unlocked
			continue --// skips the reach call, which costs a pcall plus the handler
		end
		states[id] = canReach(self, player, unlocked, id) and States.Unlockable or States.Locked
	end
	return states
end

--// pure check. ordered from basic failures down to points, so the caller gets the first reason that applies
function SkillTreeClass:CheckUnlock(player, raw, skillId): number
	local skill = self:GetSkill(skillId)
	if not skill then
		return Codes.InvalidSkill
	end
	if self:IsUnlocked(raw, skillId) then
		return Codes.AlreadyUnlocked
	end
	if not self:IsInReach(player, raw, skillId) then --// only looks at direct parents, an owned parent already passed its own checks since unlocks only happen thru Unlock
		return Codes.NotInReach
	end
	if not self:CheckRequirements(player, skillId) then --// after reach, so the custom function only runs for reachable skills
		return Codes.RequirementFailed
	end
	if raw.AvailablePoints - raw.UsedPoints < skill.SkillCost then --// last, so a structural failure is reported over "not enough points"
		return Codes.NotEnoughPoints
	end
	return Codes.Success
end

--// local on purpose, it skips every check. Unlock is the only way in
local function applyUnlock(self, raw, skillId, player)
	local skill = self._tree[skillId]
	table.insert(raw.UnlockedSkills, skillId)
	raw.UsedPoints += skill.SkillCost --// spent points are tracked, not remaining ones, so Reset just sets this to 0
	self.SkillUnlocked:Fire(skillId, player) --// fired after raw changes so listeners read the new state
end

function SkillTreeClass:Unlock(player, raw, skillId): number
	local code = self:CheckUnlock(player, raw, skillId) --// a code and not a bool, so the caller can tell the player why it failed
	if code ~= Codes.Success then
		return code
	end
	applyUnlock(self, raw, skillId, player) --// only a yielding custom requirement could let state change between check and apply
	return Codes.Success
end

function SkillTreeClass:Reset(raw, player)
	table.clear(raw.UnlockedSkills) --// cleared in place so saving and replication holding this table see it
	raw.UsedPoints = 0 --// AvailablePoints stays, so every spent point is spendable again
	self.SkillsReset:Fire(player)
end

function SkillTreeClass:GivePoints(raw, amount): number
	if not Config.IsCount(amount) or raw.AvailablePoints + amount > Config.MaxPoints then --// IsCount rejects negatives, fractions and nan. the cap is on the total so repeated calls cant pass it
		return Codes.InvalidArgs
	end
	raw.AvailablePoints += amount
	return Codes.Success
end

--// layout helpers
local function sortedIds(tree) --// pairs order isnt guaranteed, sorting keeps the layout identical on every machine
	local ids = {}
	for id in tree do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

local function orderByDepth(ids, depth)
	local ordered = table.clone(ids)
	table.sort(ordered, function(a, b)
		if depth[a] ~= depth[b] then --// parents always have a smaller depth, so their positions exist when a child is placed
			return depth[a] < depth[b]
		end
		return a < b
	end)
	return ordered
end

local function buildChildren(tree, ids) --// each skill is filed under its first Previous only, so placement sees a plain tree. other parents only matter for edges and the line average
	local children = {}
	for _, id in ids do
		if not hasPrevious(tree[id]) then
			continue
		end
		local parent = tree[id].Previous[1]
		children[parent] = children[parent] or {} --// no entry means a leaf, place() relies on that
		table.insert(children[parent], id)
	end
	return children
end

--// leaves take consecutive lines and a parent sits over the middle of its children
local function computeAutoLines(tree, ids, children)
	local autoLine = {} --// parents end up with fractional lines
	local nextSlot = 0
	local function place(id)
		local kids = children[id]
		if not kids then
			nextSlot += 1
			autoLine[id] = nextSlot
			return
		end
		local sum = 0
		for _, kid in kids do
			place(kid)
			sum += autoLine[kid]
		end
		autoLine[id] = sum / #kids
	end
	for _, id in ids do
		if not hasPrevious(tree[id]) then --// only roots start a branch, the rest are placed as descendants
			place(id)
		end
	end
	return autoLine
end

local function resolveLine(skill, id, positions, autoLine)
	local manual = (skill.AlignTo or EMPTY).OnGridLine or skill.OnGridLine --// AlignTo wins over the plain field
	if manual then
		return manual, true --// the skill still took its slot in computeAutoLines, so neighbours dont move
	end
	if not hasPrevious(skill) or #skill.Previous < 2 then
		return autoLine[id]
	end
	local sum = 0
	for _, prevId in skill.Previous do
		sum += positions[prevId][1] --// parents are already final, computePositions goes shallow first
	end
	return sum / #skill.Previous
end

--// skills sharing the same parents all land on the parents average. first one keeps the cell, the rest slide down
local function claimLine(taken, column, line, isManual)
	local used = taken[column]
	if not used then
		used = {}
		taken[column] = used
	end
	while not isManual and used[line] do --// manual lines never move
		line += 1
	end
	used[line] = true
	return line
end

local function computePositions(tree, ordered, depth, autoLine)
	local taken = {}
	local positions = {}
	for _, id in ordered do
		local skill = tree[id]
		local column = (skill.AlignTo or EMPTY).OnGridColumn or skill.OnGridColumn or depth[id] --// manual first, otherwise depth
		local line, isManual = resolveLine(skill, id, positions, autoLine)
		positions[id] = {claimLine(taken, column, line, isManual), column} --// {line, column}
	end
	return positions
end

local function getBounds(positions) --// one pass for all four limits
	local minLine, maxLine = math.huge, -math.huge
	local minColumn, maxColumn = math.huge, -math.huge
	for _, pos in positions do
		minLine = math.min(minLine, pos[1])
		maxLine = math.max(maxLine, pos[1])
		minColumn = math.min(minColumn, pos[2])
		maxColumn = math.max(maxColumn, pos[2])
	end
	return minLine, maxLine, minColumn, maxColumn
end

--// layout
function SkillTreeClass:GetLayout() --// depends only on the frozen tree, so its built once. BuildUI runs often but this part never changes
	if self._layout then
		return self._layout
	end
	if not self._tree then
		return nil
	end
	local tree = self._tree
	local ids = sortedIds(tree)
	local depth = computeDepths(tree)
	local autoLine = computeAutoLines(tree, ids, buildChildren(tree, ids)) --// step 1: tree shaped lines
	local positions = computePositions(tree, orderByDepth(ids, depth), depth, autoLine) --// step 2: manual and multi parent overrides
	local minLine, maxLine, minColumn, maxColumn = getBounds(positions) --// step 3: limits for normalising
	local lineSpan = maxLine - minLine + 1 --// +1 because both end cells are occupied
	local columnSpan = maxColumn - minColumn + 1
	local nodes, edges = {}, {}
	for _, id in ipairs(ids) do
		local skill, pos = tree[id], positions[id]
		nodes[id] = {
			Id = id,
			Line = pos[1],
			Column = pos[2],
			X = (pos[2] - minColumn + 0.5) / columnSpan, --// 0..1 with a half cell offset so the node sits mid cell and the ui can scale to any frame
			Y = (pos[1] - minLine + 0.5) / lineSpan,
			Expands = (skill.AlignTo or EMPTY).Expands == true,
			Previous = skill.Previous, --// same frozen table, no copy
		}
		for _, prevId in skill.Previous or EMPTY do --// edges use every parent, so the ui draws all requirements even though placement only followed the first
			table.insert(edges, {From = prevId, To = id})
		end
	end
	self._layout = {Lines = lineSpan, Columns = columnSpan, Nodes = nodes, Edges = edges} --// assigned last so an error above never caches a half built layout
	deepFreeze(self._layout) --// shared by every caller, so nobody can edit it for the rest
	return self._layout
end

--// ui
function SkillTreeClass:BuildUI(player, raw)
	if not self._tree or not self._uiGen then
		return
	end
	self._uiGen({ --// layout and skills come from cache, states and points are rebuilt since they depend on this players raw
		TreeId = self.Id,
		Layout = self:GetLayout(),
		Skills = self._tree,
		States = self:GetStates(player, raw),
		UsedPoints = raw.UsedPoints,
		AvailablePoints = raw.AvailablePoints, --// total, spare points are this minus UsedPoints
	})
end

return SkillTreeClass
