--// Connected Discord-GitHub

local ReplicatedStorage = game:GetService("ReplicatedStorage") --// replicatedstorage service duh

local Objects = ReplicatedStorage.Access.Value --// folder with the module paths

local Config = require(Objects:WaitForChild("SkillTreeConfig").Value) --// config module
local Signal = require(Objects:WaitForChild("SkillTreeSignal").Value) --// signal module

local Codes = Config.Codes --// result codes shortcut
local States = Config.States --// skill states shortcut
local EMPTY = table.freeze({}) --// shared empty table so we dont make new ones

local SkillTreeClass = {} --// the class
SkillTreeClass.__index = SkillTreeClass --// lets objects use the class methods

--// Helpers
local function deepFreeze(t) --// freezes a table and everything inside it
	if table.isfrozen(t) then --// already frozen
		return --// nothing to do
	end
	for _, v in t do --// loop the values
		if type(v) == "table" then --// only tables can be frozen
			deepFreeze(v) --// freeze the inner table first
		end
	end
	table.freeze(t) --// freeze this one
end

local function toSet(raw) --// unlocked list to a set
	local set = {} --// new set
	for _, id in raw.UnlockedSkills do --// loop unlocked ids
		set[id] = true --// mark as unlocked
	end
	return set --// return the set
end

local function isNumber(value) --// checks for a real number
	return type(value) == "number" and value == value and math.abs(value) < math.huge --// not nan and not inf
end

local function assertOptionalNumber(value, label, id) --// optional number check
	assert(value == nil or isNumber(value), label .. " must be a number (skill " .. id .. ")") --// nil or a real number
end

local function validatePrevious(tree, id, previous) --// checks the Previous list
	assert(type(previous) == "table", "Previous must be a table (skill " .. id .. ")") --// has to be a table
	for _, prevId in previous do --// loop each requirement
		assert(type(prevId) == "number", "Previous ids must be numbers (skill " .. id .. ")") --// id must be a number
		assert(prevId ~= id, "skill cannot require itself (skill " .. id .. ")") --// cant require itself
		assert(tree[prevId], "unknown Previous " .. tostring(prevId) .. " (skill " .. id .. ")") --// skill has to exist
	end
end

local function validateSkill(tree, id, skill) --// checks one skill
	assert(type(id) == "number", "skill ids must be numbers") --// id must be a number
	assert(type(skill) == "table", "skill must be a table (skill " .. id .. ")") --// skill must be a table
	assert(Config.IsCount(skill.SkillCost), "SkillCost must be a non-negative integer (skill " .. id .. ")") --// cost must be a whole number
	assert(type(skill.info) == "table", "missing info (skill " .. id .. ")") --// needs an info table
	assert(skill.RequireAll == nil or type(skill.RequireAll) == "boolean", "RequireAll must be a boolean (skill " .. id .. ")") --// nil or boolean
	assertOptionalNumber(skill.OnGridLine, "OnGridLine", id) --// check the line
	assertOptionalNumber(skill.OnGridColumn, "OnGridColumn", id) --// check the column
	local align = skill.AlignTo or EMPTY --// AlignTo or an empty table
	assert(type(align) == "table", "AlignTo must be a table (skill " .. id .. ")") --// has to be a table
	assertOptionalNumber(align.OnGridLine, "AlignTo.OnGridLine", id) --// check the align line
	assertOptionalNumber(align.OnGridColumn, "AlignTo.OnGridColumn", id) --// check the align column
	if skill.Previous then --// only if it has requirements
		validatePrevious(tree, id, skill.Previous) --// check them
	end
end

local function hasCycle(tree) --// looks for loops in the tree
	local state = {} --// 1 is visiting, 2 is done
	local function visit(id) --// checks one skill
		if state[id] then --// already seen
			return state[id] == 1 --// still visiting means its a loop
		end
		state[id] = 1 --// mark as visiting
		for _, prevId in tree[id].Previous or EMPTY do --// loop the requirements
			if visit(prevId) then --// loop found deeper
				return true --// pass it up
			end
		end
		state[id] = 2 --// mark as done
		return false --// no loop here
	end
	for id in tree do --// check every skill
		if visit(id) then --// found a loop
			return true --// stop here
		end
	end
	return false --// no loops
end

local function computeDepths(tree) --// depth of every skill
	local depth = {} --// saved depths
	local function visit(id) --// gets one depth
		if depth[id] then --// already saved
			return depth[id] --// return it
		end
		local d = 1 --// roots are depth 1
		for _, prevId in tree[id].Previous or EMPTY do --// loop the requirements
			d = math.max(d, visit(prevId) + 1) --// one deeper than the deepest parent
		end
		depth[id] = d --// save it
		return d --// return it
	end
	for id in tree do --// every skill
		visit(id) --// get its depth
	end
	return depth --// return all depths
end

local function hasPrevious(skill) --// checks for requirements
	return skill.Previous ~= nil and #skill.Previous > 0 --// has at least one
end

local function canReach(self, player, unlocked, skillId) --// safe reach check
	local ok, result = pcall(self._reach, self, skillId, unlocked, player) --// pcall so errors dont break it
	return ok and result == true --// only true counts
end

--// Reach and constructor
function SkillTreeClass.DefaultReach(tree, skillId, unlocked, player) --// default reach rule
	local skill = tree:GetSkill(skillId) --// get the skill
	if not skill then --// skill doesnt exist
		return false --// cant reach it
	end
	if not hasPrevious(skill) then --// no requirements
		return true --// always reachable
	end
	local needAll = skill.RequireAll == true --// all parents or just one
	for _, prevId in skill.Previous do --// loop the parents
		if needAll and not unlocked[prevId] then --// missing a parent
			return false --// cant reach it
		end
		if not needAll and unlocked[prevId] then --// has one parent
			return true --// can reach it
		end
	end
	return needAll --// true if all were owned
end

function SkillTreeClass.new(treeId: string) --// makes a new tree
	assert(type(treeId) == "string" and treeId ~= "", "treeId must be a non-empty string") --// id must be a real string
	return setmetatable({ --// give it the class methods
		Id = treeId, --// tree id
		SkillUnlocked = Signal.new(), --// fires on unlock
		SkillsReset = Signal.new(), --// fires on reset
		_tree = nil, --// skill data
		_layout = nil, --// saved layout
		_reach = SkillTreeClass.DefaultReach, --// reach rule
		_otherReq = nil, --// extra requirement
		_uiGen = nil, --// ui builder
		_hover = nil, --// hover callback
		_click = nil, --// click callback
	}, SkillTreeClass)
end

function SkillTreeClass:SetSkillTree(tree) --// loads the skill data
	for id, skill in tree do --// loop the skills
		validateSkill(tree, id, skill) --// check each one
	end
	assert(not hasCycle(tree), "skill tree contains a cycle") --// no loops allowed
	deepFreeze(tree) --// lock the data
	self._tree = tree --// save it
	self._layout = nil --// clear the old layout
end

function SkillTreeClass:HasSkillTree(): boolean --// checks if a tree is loaded
	return self._tree ~= nil --// true if loaded
end

function SkillTreeClass:GetSkill(skillId) --// gets one skill
	if type(skillId) ~= "number" or not self._tree then --// bad id or no tree
		return nil --// nothing to return
	end
	return self._tree[skillId] --// the skill
end

function SkillTreeClass:GetSkills() --// gets all skills
	return self._tree --// the tree
end

function SkillTreeClass:SetSkillTreeReachHandler(reachHandler, otherUnlockingRequirements) --// custom reach rule and extra requirement
	if reachHandler then --// one was given
		self._reach = reachHandler --// save it
	end
	self._otherReq = otherUnlockingRequirements --// save the extra requirement
end

function SkillTreeClass:SetUIGenerationHandler(handler) --// sets the ui builder
	self._uiGen = handler --// save it
end

function SkillTreeClass:SetSkillTreeUIHandlers(mouseHovered, mouseClicked) --// sets the mouse callbacks
	self._hover = mouseHovered --// save hover
	self._click = mouseClicked --// save click
end

function SkillTreeClass:GetUIHandlers() --// gets the mouse callbacks
	return self._hover, self._click --// hover and click
end

--// State and unlocking
function SkillTreeClass:IsUnlocked(raw, skillId): boolean --// checks if its unlocked
	return table.find(raw.UnlockedSkills, skillId) ~= nil --// is it in the list
end

function SkillTreeClass:IsInReach(player, raw, skillId): boolean --// checks if its reachable
	return canReach(self, player, toSet(raw), skillId) --// run the reach check
end

function SkillTreeClass:CheckRequirements(player, skillId): boolean --// checks the extra requirement
	local skill = self:GetSkill(skillId) --// get the skill
	if not skill then --// skill doesnt exist
		return false --// fail
	end
	local fn = skill.OtherUnlockingRequirements or self._otherReq --// skill check first then global
	if not fn then --// no extra requirement
		return true --// pass
	end
	local ok, result = pcall(fn, player, skill, skillId) --// pcall so errors dont break it
	return ok and result == true --// only true passes
end

function SkillTreeClass:GetState(player, raw, skillId) --// gets one skill state
	if self:IsUnlocked(raw, skillId) then --// owned
		return States.Unlocked --// unlocked
	end
	if self:IsInReach(player, raw, skillId) then --// reachable
		return States.Unlockable --// can unlock
	end
	return States.Locked --// locked
end

function SkillTreeClass:GetStates(player, raw) --// gets every skill state
	local unlocked = toSet(raw) --// make the set once
	local states = {} --// all states
	for id in self._tree do --// loop the skills
		if unlocked[id] then --// owned
			states[id] = States.Unlocked --// unlocked
			continue --// skip the reach check
		end
		states[id] = canReach(self, player, unlocked, id) and States.Unlockable or States.Locked --// unlockable or locked
	end
	return states --// return all states
end

function SkillTreeClass:CheckUnlock(player, raw, skillId): number --// checks if it can be unlocked
	local skill = self:GetSkill(skillId) --// get the skill
	if not skill then --// skill doesnt exist
		return Codes.InvalidSkill --// invalid skill
	end
	if self:IsUnlocked(raw, skillId) then --// already owned
		return Codes.AlreadyUnlocked --// already unlocked
	end
	if not self:IsInReach(player, raw, skillId) then --// only checks this skill
		return Codes.NotInReach --// parents missing
	end
	if not self:CheckRequirements(player, skillId) then --// extra requirement
		return Codes.RequirementFailed --// requirement failed
	end
	if raw.AvailablePoints - raw.UsedPoints < skill.SkillCost then --// spare points vs cost
		return Codes.NotEnoughPoints --// too broke lol
	end
	return Codes.Success --// all good
end

function SkillTreeClass:ApplyUnlocked(raw, skillId, player) --// saves the unlock
	local skill = self:GetSkill(skillId) --// get the skill
	if not skill or self:IsUnlocked(raw, skillId) then --// bad id or already owned
		return false --// failed
	end
	table.insert(raw.UnlockedSkills, skillId) --// add to the unlocked list
	raw.UsedPoints += skill.SkillCost --// spend the points
	self.SkillUnlocked:Fire(skillId, player) --// fire the signal
	return true --// worked
end

function SkillTreeClass:Unlock(player, raw, skillId): number --// unlocks a skill
	local code = self:CheckUnlock(player, raw, skillId) --// check first
	if code ~= Codes.Success then --// something failed
		return code --// return the code
	end
	self:ApplyUnlocked(raw, skillId, player) --// apply it
	return Codes.Success --// success
end

function SkillTreeClass:Reset(raw, player) --// resets the tree
	table.clear(raw.UnlockedSkills) --// clear the list
	raw.UsedPoints = 0 --// refund the points
	self.SkillsReset:Fire(player) --// fire the signal
end

function SkillTreeClass:GivePoints(raw, amount): number --// adds skill points
	if not Config.IsCount(amount) or raw.AvailablePoints + amount > Config.MaxPoints then --// bad amount or over the cap
		return Codes.InvalidArgs --// invalid
	end
	raw.AvailablePoints += amount --// add the points
	return Codes.Success --// success
end

--// Layout helpers
local function sortedIds(tree) --// sorted list of ids
	local ids = {} --// the list
	for id in tree do --// loop the skills
		table.insert(ids, id) --// add the id
	end
	table.sort(ids) --// sort it
	return ids --// return it
end

local function orderByDepth(ids, depth) --// sorts ids by depth
	local ordered = table.clone(ids) --// copy the list
	table.sort(ordered, function(a, b) --// sort the copy
		if depth[a] ~= depth[b] then --// different depths
			return depth[a] < depth[b] --// shallow first
		end
		return a < b --// same depth so lowest id first
	end)
	return ordered --// return it
end

local function buildChildren(tree, ids) --// parent to children map
	local children = {} --// the map
	for _, id in ids do --// loop the skills
		if not hasPrevious(tree[id]) then --// root skill
			continue --// skip it
		end
		local parent = tree[id].Previous[1] --// first requirement is the main parent
		children[parent] = children[parent] or {} --// make the list if needed
		table.insert(children[parent], id) --// add the child
	end
	return children --// return the map
end

local function computeAutoLines(tree, ids, children) --// automatic line for every skill
	local autoLine = {} --// saved lines
	local nextSlot = 0 --// next free line
	local function place(id) --// places one skill
		local kids = children[id] --// its children
		if not kids then --// no children
			nextSlot += 1 --// take the next line
			autoLine[id] = nextSlot --// save it
			return --// done
		end
		local sum = 0 --// total of the children lines
		for _, kid in kids do --// loop the children
			place(kid) --// place the child first
			sum += autoLine[kid] --// add its line
		end
		autoLine[id] = sum / #kids --// middle of the children
	end
	for _, id in ids do --// loop the skills
		if not hasPrevious(tree[id]) then --// root skill
			place(id) --// place the branch
		end
	end
	return autoLine --// return the lines
end

local function resolveLine(skill, id, positions, autoLine) --// final line for a skill
	local manual = (skill.AlignTo or EMPTY).OnGridLine or skill.OnGridLine --// manual line
	if manual then --// one was set
		return manual --// use it
	end
	if not hasPrevious(skill) or #skill.Previous < 2 then --// zero or one parent
		return autoLine[id] --// use the auto line
	end
	local sum = 0 --// total of the parent lines
	for _, prevId in skill.Previous do --// loop the parents
		sum += positions[prevId][1] --// add the parent line
	end
	return sum / #skill.Previous --// middle of the parents
end

local function computePositions(tree, ordered, depth, autoLine) --// line and column for every skill
	local positions = {} --// saved positions
	for _, id in ordered do --// shallow first
		local skill = tree[id] --// current skill
		local column = (skill.AlignTo or EMPTY).OnGridColumn or skill.OnGridColumn or depth[id] --// manual column or depth
		positions[id] = {resolveLine(skill, id, positions, autoLine), column} --// save the position
	end
	return positions --// return them
end

local function getBounds(positions) --// min and max of the grid
	local minLine, maxLine = math.huge, -math.huge --// line limits
	local minColumn, maxColumn = math.huge, -math.huge --// column limits
	for _, pos in positions do --// loop the positions
		minLine = math.min(minLine, pos[1]) --// lowest line
		maxLine = math.max(maxLine, pos[1]) --// highest line
		minColumn = math.min(minColumn, pos[2]) --// lowest column
		maxColumn = math.max(maxColumn, pos[2]) --// highest column
	end
	return minLine, maxLine, minColumn, maxColumn --// all four limits
end

--// Layout
function SkillTreeClass:GetLayout() --// builds the layout for the ui
	if self._layout then --// already built
		return self._layout --// return the saved one
	end
	local tree = self._tree --// shorter name
	local ids = sortedIds(tree) --// sorted ids
	local depth = computeDepths(tree) --// depths
	local autoLine = computeAutoLines(tree, ids, buildChildren(tree, ids)) --// automatic lines
	local positions = computePositions(tree, orderByDepth(ids, depth), depth, autoLine) --// final positions
	local minLine, maxLine, minColumn, maxColumn = getBounds(positions) --// grid limits
	local lineSpan = maxLine - minLine + 1 --// total lines
	local columnSpan = maxColumn - minColumn + 1 --// total columns
	local nodes, edges = {}, {} --// output tables
	for _, id in ipairs(ids) do --// loop the skills in order
		local skill, pos = tree[id], positions[id] --// skill and its position
		nodes[id] = { --// node data
			Id = id, --// skill id
			Line = pos[1], --// line
			Column = pos[2], --// column
			X = (pos[2] - minColumn + 0.5) / columnSpan, --// x from 0 to 1
			Y = (pos[1] - minLine + 0.5) / lineSpan, --// y from 0 to 1
			Expands = (skill.AlignTo or EMPTY).Expands == true, --// should it expand
			Previous = skill.Previous, --// parents
		}
		for _, prevId in skill.Previous or EMPTY do --// loop the parents
			table.insert(edges, {From = prevId, To = id}) --// add a link
		end
	end
	self._layout = {Lines = lineSpan, Columns = columnSpan, Nodes = nodes, Edges = edges} --// save the layout
	deepFreeze(self._layout) --// lock it
	return self._layout --// return it
end

--// UI
function SkillTreeClass:BuildUI(player, raw) --// sends the ui data to the builder
	if not self._tree or not self._uiGen then --// missing tree or builder
		return --// nothing to build
	end
	self._uiGen({ --// call the ui builder
		TreeId = self.Id, --// tree id
		Layout = self:GetLayout(), --// layout
		Skills = self._tree, --// skill data
		States = self:GetStates(player, raw), --// skill states
		UsedPoints = raw.UsedPoints, --// spent points
		AvailablePoints = raw.AvailablePoints, --// total player points
	})
end

return SkillTreeClass --// return the module
