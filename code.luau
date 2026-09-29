--// modules

local Proxy = require(script.Proxy) --// wraps the class for every field (read or write)
local Signal = require(script.Signal) --// custom signal, tells me how many listeners are connected
local SynchronousTaskManager = require(script.SynchronousTaskManager) --// basically a queue that runs in a different thread

--// services

local data_store_service = game:GetService("DataStoreService")
local memory_store_service = game:GetService("MemoryStoreService")
local http_service = game:GetService("HttpService")
local run_service = game:GetService("RunService")

--// state

local data_stores = {} --// id to store, so calling new twice on one key gives the same store back
local bind_to_close = {} --// stores that btc (duh)
local active = true --// goes false at shutdown so late stores dont sign up for a save that already happened

local alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!$%&',./:;=?@[]^_`{}~" --// the digits for my number encoding, dont reorder or old saves break
local base = #alphabet
local bytes = {} --// char code to digit value, decode needs this to go backwards
for i = 1, base do bytes[string.byte(alphabet, i)] = i - 1 end

local end_mark = "\0" --// marks the end of a string or table in the compressed text
local type_pattern = "([-+<>()#|*\0])" --// finds the next marker while reading compressed text
local digit_pattern = "([^-+<>()#|*\0]*)" --// grabs the digits after a number marker
local number_signs = {["<"] = -1, [">"] = 1, ["("] = -1, [")"] = 1} --// marker to sign round brackets mean it had decimals

local data_store_class = {} --// all the methods and stuff blah vlah blah
local constructor = {} --// what other scripts get (new, hidden an find)

--// these call each other so they get declared here and filled in later
local open_task, read_task, lock_task, save_task, close_task, destroy_task

--// types

export type Constructor = {
	new: (name: string, scope: string, key: string?) -> DataStore,
	hidden: (name: string, scope: string, key: string?) -> DataStore,
	find: (name: string, scope: string, key: string?) -> DataStore?,
	Response: {Success: string, Saved: string, Locked: string, State: string, Error: string},
}

export type DataStore = {
	[any]: any,
	Value: any,
	Metadata: {[string]: any},
	UserIds: {any},
	SaveInterval: number,
	SaveDelay: number,
	LockInterval: number,
	LockAttempts: number,
	SaveOnClose: boolean,
	Id: string,
	UniqueId: string,
	Key: string,
	State: boolean?,
	Hidden: boolean,
	AttemptsRemaining: number,
	CreatedTime: number,
	UpdatedTime: number,
	Version: string,
	CompressedValue: string,
	StateChanged: Signal.Signal,
	Saving: Signal.Signal,
	Saved: Signal.Signal,
	AttemptsChanged: Signal.Signal,
	ProcessQueue: Signal.Signal,
	Open: (self: DataStore, template: any?) -> (string, any),
	Read: (self: DataStore, template: any?) -> (string, any),
	Save: (self: DataStore) -> (string, any),
	Close: (self: DataStore) -> (string, any),
	Destroy: (self: DataStore) -> (string, any),
	Queue: (self: DataStore, value: any, expiration: number?, priority: number?) -> (string, any),
	Remove: (self: DataStore, id: string) -> (string, any),
	Clone: (self: DataStore) -> any,
	Reconcile: (self: DataStore, template: any) -> (),
	Usage: (self: DataStore) -> (number, number),
}

--// helpers

local function clone(original)
	if type(original) ~= "table" then return original end --// numbers and strings copy by themselves
	local copy = {}
	for index, value in original do copy[index] = clone(value) end --// go deep so nested tables arent shared
	return copy
end

local function reconcile(target, template)
	for index, value in template do
		if type(index) == "number" then continue end --// array slots are real data, leave them
		if target[index] == nil then
			target[index] = clone(value) --// missing key, hand it a fresh default
		elseif type(target[index]) == "table" and type(value) == "table" then
			reconcile(target[index], value) --// both are tables, check inside too
		end
	end
end

--// apply template, leaves existing vals
local function apply_template(public, template)
	if public.Value == nil then
		public.Value = clone(template)
	elseif type(public.Value) == "table" and type(template) == "table" then
		reconcile(public.Value, template)
	end
end

--// datastores fail randomly so try a few times with a 1 second wait between
local function retry(attempts, fn)
	local success, first, second
	for i = 1, attempts do
		if i > 1 then task.wait(1) end
		success, first, second = pcall(fn)
		if success then break end
	end
	return success, first, second
end

--// check up on every thread that was waiting on a task
local function resume_all(running, ...)
	for thread in running:Iterate() do task.defer(thread, ...) end
end

--// close and destroy only say Saved if a save really happened
local function resume_saved(running, response, response_data)
	if response == "Saved" then
		resume_all(running, response, response_data)
	else
		resume_all(running, "Success")
	end
end

--// true if a close or destroy is waiting in line, timers should stay off then
local function is_closing(internal)
	return internal.task_manager:FindLast(close_task) ~= nil or internal.task_manager:FindLast(destroy_task) ~= nil
end

--// make sure you really passed a datastore
local function get_internal(proxy, action)
	local internal = getmetatable(proxy)
	if type(internal) ~= "table" or internal.__shared ~= data_store_class.__shared then
		error("Attempt to " .. action .. " failed: Passed value is not a DataStore", 3) --// 3 blames whoever called the method
	end
	return internal
end

--// compression, squishes data into a short string so more fits in the size limit

local function encode(value)
	if value == 0 then return "0" end
	local digits = {}
	while value > 0 do
		local digit = value % base
		table.insert(digits, alphabet:sub(digit + 1, digit + 1)) --// lowest digit goes first
		value = math.floor(value / base)
	end
	return table.concat(digits)
end

local function decode(text)
	local number, power = 0, 1
	for _, code in {string.byte(text, 1, #text)} do
		number += bytes[code] * power --// same order encode used
		power *= base
	end
	return number
end

--// compress settings sit in the metadata so a store always unpacks the way it was packed
local function compress_settings(metadata)
	local settings = metadata.Compress
	local safety = settings.Safety
	if safety == nil then safety = true end
	return settings.Level or 2, 10 ^ (settings.Decimals or 3), safety
end

local function compress(value, level, decimals, safety)
	local data = {}
	if type(value) == "boolean" then
		table.insert(data, if value then "+" else "-")
	elseif type(value) == "number" then
		if value % 1 == 0 then
			table.insert(data, if value < 0 then "<" .. encode(-value) else ">" .. encode(value)) --// whole numbers
		else
			table.insert(data, if value < 0 then "(" .. encode(math.round(-value * decimals)) else ")" .. encode(math.round(value * decimals))) --// decimals get stored as big whole numbers
		end
	elseif type(value) == "string" then
		if safety then value = value:gsub(end_mark, " ") end --// a stray end mark inside would break the format
		table.insert(data, "#" .. value .. end_mark)
	elseif type(value) == "table" then
		if #value > 0 and level == 2 then
			table.insert(data, "|") --// real arrays skip their keys
			for i = 1, #value do table.insert(data, compress(value[i], level, decimals, safety)) end
		else
			table.insert(data, "*") --// dictionaries go key then value, over and over
			for key, item in value do
				table.insert(data, compress(key, level, decimals, safety))
				table.insert(data, compress(item, level, decimals, safety))
			end
		end
		table.insert(data, end_mark)
	end
	return table.concat(data)
end

--// gives back the value and where it stopped reading so the caller can keep going
local function decompress(text, decimals, index)
	local _, position, kind = text:find(type_pattern, index or 1)
	if kind == "-" then return false, position end
	if kind == "+" then return true, position end
	local sign = number_signs[kind]
	if sign ~= nil then
		local _, stop, digits = text:find(digit_pattern, position + 1)
		local number = sign * decode(digits)
		if kind == "(" or kind == ")" then number /= decimals end --// undo the decimal scaling
		return number, stop
	elseif kind == "#" then
		local _, stop, str = text:find("(.-)" .. end_mark, position + 1) --// read up to the first end mark
		return str, stop
	elseif kind == "|" then
		local array = {}
		while true do
			local item
			item, position = decompress(text, decimals, position + 1)
			if item == nil then break end --// hit the end mark then break arraeyyy
			table.insert(array, item)
		end
		return array, position
	elseif kind == "*" then
		local dictionary = {}
		while true do
			local key, item
			key, position = decompress(text, decimals, position + 1)
			if key == nil then break end
			item, position = decompress(text, decimals, position + 1)
			dictionary[key] = item
		end
		return dictionary, position
	end
	return nil, position --// end mark or nothing left
end

--// session lock and datastore

--// grabs the "Id" (SPELT EXACTLY LIKE THAT) key in memorystore, this is what stops two servers saving over each other
local function lock_session(internal, attempts)
	local public = internal.__public
	local lock_interval, lock_attempts = public.LockInterval, public.LockAttempts
	local owner, lock_time
	local success, value = retry(attempts, function()
		lock_time = os.clock() --// time stamp every try
		return internal.memory_store:UpdateAsync("Id", function(current)
			owner = current
			return if owner == nil or owner == public.UniqueId then public.UniqueId else nil end, lock_interval * lock_attempts + 30) --// returning nil means someone else has it
	end)
	if not success then return "Error", value end
	if value == nil then return "Locked", owner end --// tell the caller who has it
	internal.lock_time = lock_time + lock_interval * lock_attempts
	internal.active_lock_interval = lock_interval
	public.AttemptsRemaining = lock_attempts
	return "Success"
end

--// gives the lock back (0 expiry means destroy)
local function unlock_session(internal, attempts)
	local public = internal.__public
	local owner
	local success, value = retry(attempts, function()
		return internal.memory_store:UpdateAsync("Id", function(current)
			owner = current
			return if owner == public.UniqueId then public.UniqueId else nil end, 0) --// only release if owned
	end)
	if not success then return "Error", value end
	if value == nil and owner ~= nil then return "Locked", owner end
	return "Success"
end

local function load_data(internal, attempts)
	local public = internal.__public
	local success, value, info = retry(attempts, function() return internal.data_store:GetAsync(public.Key) end)
	if not success then return "Error", value end
	if info == nil then
		public.Metadata, public.UserIds, public.CreatedTime, public.UpdatedTime, public.Version = {}, {}, 0, 0, "" --// new key = nothing saved yet
	else
		public.Metadata, public.UserIds, public.CreatedTime, public.UpdatedTime, public.Version = info:GetMetadata(), info:GetUserIds(), info.CreatedTime, info.UpdatedTime, info.Version
	end
	if type(public.Metadata.Compress) == "table" then
		public.CompressedValue = value
		local _, decimals = compress_settings(public.Metadata)
		public.Value = decompress(value, decimals) --// decompress also returns a position, we only want the value
	else
		public.Value = value
	end
	return "Success"
end

local function save_data(proxy, attempts)
	local internal = getmetatable(proxy)
	local public = internal.__public
	local since_save = os.clock() - internal.save_time
	if since_save < public.SaveDelay then task.wait(public.SaveDelay - since_save) end --// wait out the cooldown between saves
	public.Saving:Fire(public.Value, proxy)
	local success, value
	if public.Value == nil then
		success, value = retry(attempts, function() return internal.data_store:RemoveAsync(public.Key) end) --// nil value means delete the key
		if success then public.Metadata, public.UserIds, public.CreatedTime, public.UpdatedTime, public.Version = {}, {}, 0, 0, "" end
	else
		local to_save = public.Value
		if type(public.Metadata.Compress) == "table" then
			local level, decimals, safety = compress_settings(public.Metadata)
			public.CompressedValue = compress(public.Value, level, decimals, safety)
			to_save = public.CompressedValue --// the string gets saved (not table)
		end
		internal.options:SetMetadata(public.Metadata)
		success, value = retry(attempts, function() return internal.data_store:SetAsync(public.Key, to_save, public.UserIds, internal.options) end)
		if success then public.Version = value end --// setasync hands back the new version id
	end
	if not success then
		public.Saved:Fire("Error", value, proxy)
		return "Error", value
	end
	internal.save_time = os.clock()
	public.Saved:Fire("Saved", public.Value, proxy)
	return "Saved", public.Value
end

--// timers, stop comes first so the others can use it

local function stop_save_timer(internal)
	if internal.save_thread == nil then return end
	task.cancel(internal.save_thread)
	internal.save_thread = nil
end

local function stop_lock_timer(internal)
	if internal.lock_thread == nil then return end
	task.cancel(internal.lock_thread)
	internal.lock_thread = nil
end

local function save_timer_ended(proxy)
	local internal = getmetatable(proxy)
	internal.save_thread = nil
	if internal.task_manager:FindLast(save_task) ~= nil then return end --// if already saving dont stack another save on
	internal.task_manager:InsertBack(save_task, proxy)
end

local function lock_timer_ended(proxy)
	local internal = getmetatable(proxy)
	internal.lock_thread = nil
	if internal.task_manager:FindFirst(lock_task) ~= nil then return end
	internal.task_manager:InsertBack(lock_task, proxy)
end

local function start_save_timer(proxy)
	local internal = getmetatable(proxy)
	stop_save_timer(internal) --// never two timers at once
	if internal.__public.SaveInterval == 0 then return end --// 0 means autosave is off
	internal.save_thread = task.delay(internal.__public.SaveInterval, save_timer_ended, proxy)
end

local function start_lock_timer(proxy)
	local internal = getmetatable(proxy)
	stop_lock_timer(internal)
	--// lock_time is when the whole lock runs out, so walk back by the attempts left to find when this round started
	local start_time = internal.lock_time - internal.__public.AttemptsRemaining * internal.active_lock_interval
	internal.lock_thread = task.delay(start_time - os.clock() + internal.active_lock_interval, lock_timer_ended, proxy)
end

--// lets other servers send this keys messages through memorystore (baiscally a waiting line queue thing)

local function process_queue(proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	if public.State ~= true or public.ProcessQueue.Connections == 0 or internal.processing_queue then return end --// needs an open store + listener and ONE loop
	internal.processing_queue = true
	while true do
		local success, values, id = pcall(internal.queue.ReadAsync, internal.queue, 100, false, 30) --// waits up to 30s for items
		if public.State ~= true or public.ProcessQueue.Connections == 0 then break end
		if success and id ~= nil then
			public.ProcessQueue:Fire(id, values, proxy)
		elseif not success then
			task.wait(1) --// failed instantly wait to not cause server overload and die
		end
	end
	internal.processing_queue = false
end

--// fires when someone connects to process_queue then listener starts loop
local function signal_connected(connected, signal)
	if connected == false then return end
	process_queue(signal.DataStore)
end

--// task manager

function open_task(running, proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	local response, response_data = lock_session(internal, 3)
	if response ~= "Success" then return resume_all(running, response, response_data) end
	response, response_data = load_data(internal, 3)
	if response ~= "Success" then
		unlock_session(internal, 3) --// got the lock but cant load so give it back so nobody gets stuck so so so so so so
		return resume_all(running, response, response_data)
	end
	public.State = true
	if not is_closing(internal) then
		start_save_timer(proxy)
		start_lock_timer(proxy)
	end
	for thread, template in running:Iterate() do
		apply_template(public, template) --// apply template before resum
		task.defer(thread, response)
	end
	if not internal.processing_queue and public.ProcessQueue.Connections > 0 then task.defer(process_queue, proxy) end
	public.StateChanged:Fire(true, proxy)
end

function read_task(running, proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	if public.State == true then return resume_all(running, "State", "Open") end --// got opened while this waited in line
	local response, response_data = load_data(internal, 3)
	if response ~= "Success" then return resume_all(running, response, response_data) end
	for thread, template in running:Iterate() do
		apply_template(public, template)
		task.defer(thread, response)
	end
end

--// runs every lock intervul to keep the lock (too many failes closes store)
function lock_task(running, proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	local before = public.AttemptsRemaining
	local response, response_data = lock_session(internal, 3)
	if response ~= "Success" then public.AttemptsRemaining -= 1 end
	if public.AttemptsRemaining ~= before then public.AttemptsChanged:Fire(public.AttemptsRemaining, proxy) end
	if public.AttemptsRemaining > 0 then
		if not is_closing(internal) then start_lock_timer(proxy) end
	else
		public.State = false --// another server probably has the key
		stop_lock_timer(internal)
		stop_save_timer(internal)
		if public.SaveOnClose then save_data(proxy, 3) end
		unlock_session(internal, 3)
		public.StateChanged:Fire(false, proxy)
	end
	resume_all(running, response, response_data)
end

function save_task(running, proxy)
	local internal = getmetatable(proxy)
	if internal.__public.State == false then return resume_all(running, "State", "Closed") end
	stop_save_timer(internal)
	running:End() --// new task instead of editing one thats mid-saev
	local response, response_data = save_data(proxy, 3)
	if not is_closing(internal) then start_save_timer(proxy) end
	resume_all(running, response, response_data)
end

function close_task(running, proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	if public.State == false then return resume_all(running, "Success") end
	public.State = false --// close before saving
	local response, response_data
	if public.SaveOnClose then response, response_data = save_data(proxy, 3) end
	unlock_session(internal, 3)
	public.StateChanged:Fire(false, proxy)
	resume_saved(running, response, response_data)
end

function destroy_task(running, proxy)
	local internal = getmetatable(proxy)
	local public = internal.__public
	local was_open = public.State ~= false
	public.State = nil --// nil means its gone, false means closed
	local response, response_data
	if was_open then
		if public.SaveOnClose then response, response_data = save_data(proxy, 3) end
		unlock_session(internal, 3)
	end
	public.StateChanged:Fire(nil, proxy)
	for _, name in {"StateChanged", "Saving", "Saved", "AttemptsChanged", "ProcessQueue"} do
		public[name]:DisconnectAll() --// stop listeners so nothing leaks
	end
	bind_to_close[public.UniqueId] = nil
	resume_saved(running, response, response_data)
end

--// class

data_store_class.__tostring = function()
	return "DataStore"
end

data_store_class.__shared = {
	Open = function(proxy, template)
		local internal = get_internal(proxy, "Open")
		local public, tasks = internal.__public, internal.task_manager
		if public.State == nil then return "State", "Destroyed" end
		local pending = tasks:FindFirst(open_task)
		if pending ~= nil then return pending:Wait(template) end --// open already running so just hop on it
		if tasks:FindLast(destroy_task) ~= nil then return "State", "Destroying" end
		if public.State == true and tasks:FindLast(close_task) == nil then
			apply_template(public, template) --// open = fill in the template
			return "Success"
		end
		return tasks:InsertBack(open_task, proxy):Wait(template)
	end,
	Read = function(proxy, template)
		local internal = get_internal(proxy, "Read")
		local public, tasks = internal.__public, internal.task_manager
		local pending = tasks:FindFirst(read_task)
		if pending ~= nil then return pending:Wait(template) end
		if public.State == true and tasks:FindLast(close_task) == nil then return "State", "Open" end --// read is for closed stores, an open one already has the value
		return tasks:InsertBack(read_task, proxy):Wait(template)
	end,
	Save = function(proxy)
		local internal = get_internal(proxy, "Save")
		local public, tasks = internal.__public, internal.task_manager
		if public.State == false then return "State", "Closed" end
		if public.State == nil then return "State", "Destroyed" end
		local pending = tasks:FindFirst(save_task)
		if pending ~= nil then return pending:Wait() end
		if tasks:FindLast(close_task) ~= nil then return "State", "Closing" end
		if tasks:FindLast(destroy_task) ~= nil then return "State", "Destroying" end
		return tasks:InsertBack(save_task, proxy):Wait()
	end,
	Close = function(proxy)
		local internal = get_internal(proxy, "Close")
		local public, tasks = internal.__public, internal.task_manager
		if public.State == nil then return "Success" end
		local pending = tasks:FindFirst(close_task)
		if pending ~= nil then return pending:Wait() end
		if public.State == false and tasks:FindLast(open_task) == nil then return "Success" end --// already closed and nothing is opening it
		pending = tasks:FindFirst(destroy_task)
		if pending ~= nil then return pending:Wait() end
		stop_lock_timer(internal)
		stop_save_timer(internal)
		return tasks:InsertBack(close_task, proxy):Wait()
	end,
	Destroy = function(proxy)
		local internal = get_internal(proxy, "Destroy")
		local public, tasks = internal.__public, internal.task_manager
		if public.State == nil then return "Success" end
		data_stores[public.Id] = nil --// freed right away so new can make a fresh store for the same key
		stop_lock_timer(internal)
		stop_save_timer(internal)
		return (tasks:FindFirst(destroy_task) or tasks:InsertBack(destroy_task, proxy)):Wait()
	end,
	Queue = function(proxy, value, expiration, priority)
		local internal = get_internal(proxy, "Queue")
		if expiration ~= nil and type(expiration) ~= "number" then error("Attempt to Queue failed: Passed value is not nil or number", 2) end
		if priority ~= nil and type(priority) ~= "number" then error("Attempt to Queue failed: Passed value is not nil or number", 2) end
		local success, error_message = retry(3, function() return internal.queue:AddAsync(value, expiration or 604800, priority) end) --// items last a week unless told otherwise
		if success then return "Success" end
		return "Error", error_message
	end,
	Remove = function(proxy, id)
		local internal = get_internal(proxy, "Remove")
		if type(id) ~= "string" then error("Attempt to Remove failed: Passed value is not a string", 2) end
		local success, error_message = retry(3, function() return internal.queue:RemoveAsync(id) end)
		if success then return "Success" end
		return "Error", error_message
	end,
	Clone = function(proxy)
		return clone(get_internal(proxy, "Clone").__public.Value)
	end,
	Reconcile = function(proxy, template)
		apply_template(get_internal(proxy, "Reconcile").__public, template)
	end,
	Usage = function(proxy)
		local public = get_internal(proxy, "Usage").__public
		if public.Value == nil then return 0, 0 end
		local measured = public.Value
		if type(public.Metadata.Compress) == "table" then
			local level, decimals, safety = compress_settings(public.Metadata)
			public.CompressedValue = compress(public.Value, level, decimals, safety)
			measured = public.CompressedValue --// the compressed size is what counts against the limit
		end
		local used = #http_service:JSONEncode(measured)
		return used, used / 4194303 --// how much of the 4mb cap is used
	end,
}

--// makes a setter that checks type and range so i dont write the same checks over and over
local function ranged_setter(name, min, max)
	return function(_, internal, value)
		if type(value) ~= "number" then error(`Attempt to set {name} failed: Passed value is not a number`, 3) end
		if value < min then error(`Attempt to set {name} failed: Passed value is less than {min}`, 3) end
		if value > max then error(`Attempt to set {name} failed: Passed value is more than {max}`, 3)end
		internal.__public[name] = value
	end
end

local function table_setter(name)
	return function(_, internal, value)
		if type(value) ~= "table" then error(`Attempt to set {name} failed: Passed value is not a table`, 3) end
		internal.__public[name] = value
	end
end

data_store_class.__set = {
	Metadata = table_setter("Metadata"),
	UserIds = table_setter("UserIds"),
	SaveDelay = ranged_setter("SaveDelay", 0, 10),
	LockInterval = ranged_setter("LockInterval", 10, 1000),
	LockAttempts = ranged_setter("LockAttempts", 1, 100),
	SaveOnClose = function(_, internal, value)
		if type(value) ~= "boolean" then error("Attempt to set SaveOnClose failed: Passed value is not a boolean", 3) end
		internal.__public.SaveOnClose = value
	end,
	--// 0 turns autosave off, anything else must be 10 to 1000, so the plain ranged setter cant do it
	SaveInterval = function(proxy, internal, value)
		if type(value) ~= "number" then error("Attempt to set SaveInterval failed: Passed value is not a number", 3) end
		if (value < 10 and value ~= 0) or value > 1000 then error("Attempt to set SaveInterval failed: Passed value is not 0 or between 10 and 1000", 3) end
		local public = internal.__public
		if value == public.SaveInterval then return end
		public.SaveInterval = value
		if public.State ~= true then return end --// timers only run while open
		if value == 0 then
			stop_save_timer(internal)
		elseif not is_closing(internal) then
			start_save_timer(proxy) --// restart so the new interval kicks in now
		end
	end,
}

for _, name in {"Id", "UniqueId", "Key", "State", "Hidden", "AttemptsRemaining", "CreatedTime", "UpdatedTime", "Version", "CompressedValue", "StateChanged", "Saving", "Saved", "AttemptsChanged", "ProcessQueue"} do
	data_store_class.__set[name] = false --// false makes proxy block writes, these are read only
end

--// constructor

local function build(id, name, scope, key, hidden)
	local proxy, internal = Proxy.new(data_store_class, {
		Metadata = {},
		UserIds = {},
		SaveInterval = 30,
		SaveDelay = 0,
		LockInterval = 60,
		LockAttempts = 5,
		SaveOnClose = true,
		Id = id,
		UniqueId = http_service:GenerateGUID(false), --// how a server tells its own lock from someone elses
		Key = key,
		State = false,
		Hidden = hidden,
		AttemptsRemaining = 0,
		CreatedTime = 0,
		UpdatedTime = 0,
		Version = "",
		CompressedValue = "",
		StateChanged = Signal.new(),
		Saving = Signal.new(),
		Saved = Signal.new(),
		AttemptsChanged = Signal.new(),
		ProcessQueue = Signal.new(),
	})
	internal.task_manager = SynchronousTaskManager.new()
	internal.lock_time = -math.huge --// minus infinity so a fresh store never looks locked
	internal.save_time = -math.huge --// and never looks like it just saved
	internal.active_lock_interval = 0
	internal.processing_queue = false
	internal.data_store = data_store_service:GetDataStore(name, scope)
	internal.memory_store = memory_store_service:GetSortedMap(id)
	internal.queue = memory_store_service:GetQueue(id)
	internal.options = Instance.new("DataStoreSetOptions") --// reused every save to carry the metadata
	internal.__public.ProcessQueue.DataStore = proxy --// so signal_connected can go back to the store
	internal.__public.ProcessQueue.Connected = signal_connected
	if active then bind_to_close[internal.__public.UniqueId] = proxy end
	return proxy
end

local function make_id(name, scope, key)
	if key == nil then key, scope = scope, "global" end
	return name .. "/" .. scope .. "/" .. key, scope, key
end

constructor.new = function(name, scope, key)
	local id, real_scope, real_key = make_id(name, scope, key)
	if data_stores[id] ~= nil then return data_stores[id] end
	local proxy = build(id, name, real_scope, real_key, false)
	data_stores[id] = proxy
	return proxy
end

--// hidden stores skip the data_stores list so they are never given on accident
constructor.hidden = function(name, scope, key)
	local id, real_scope, real_key = make_id(name, scope, key)
	return build(id, name, real_scope, real_key, true)
end

constructor.find = function(name, scope, key)
	return data_stores[(make_id(name, scope, key))]
end

constructor.Response = {Success = "Success", Saved = "Saved", Locked = "Locked", State = "State", Error = "Error"}

--// shutdown

--// every store gets destroyed so it saves and unlocks before the server lowk dies
local function close_all()
	active = false
	for _, proxy in bind_to_close do
		local internal = getmetatable(proxy)
		if internal.__public.State == nil then continue end --// already destroyed
		data_stores[internal.__public.Id] = nil
		stop_lock_timer(internal)
		stop_save_timer(internal)
		if internal.task_manager:FindFirst(destroy_task) == nil then internal.task_manager:InsertBack(destroy_task, proxy) end
	end
	while next(bind_to_close) ~= nil do task.wait() end --// destroy_task removes each entry wait till the list is empty
end

if not run_service:IsStudio() then
	game:BindToClose(close_all) --// skipped in studio or test sessions would hang on real datastores
end

return table.freeze(constructor) :: Constructor
