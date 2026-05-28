--[[
	DataStoreSafe — a production-grade wrapper around DataStoreService.

	Solves the four problems every shipping Roblox game eventually hits:

		1. Session locking         — two servers must never own the same key.
		2. Transient failure       — DataStore calls fail, sometimes a lot.
		3. Schema drift            — saved data lags behind code changes.
		4. Shutdown saves          — flushing data when the server dies.

	Storage shape
	-------------
		{
			data    = <user-defined table>,
			version = <integer schema version>,
			session = { serverId = <guid>, refreshedAt = <unix seconds> } | nil,
		}

	Quickstart
	----------
		local DataStoreSafe = require(ServerStorage.DataStoreSafe)

		local store = DataStoreSafe.new("PlayerData", {
			template = {
				coins = 0,
				level = 1,
				inventory = {},
			},
			autoSaveInterval = 60,
			schemaVersion = 1,
			migrate = function(data, from, to)
				-- mutate data in place or return a new table
				return data
			end,
		})

		Players.PlayerAdded:Connect(function(player)
			local profile = store:Load(player.UserId)
			if not profile then
				player:Kick("Could not load your save — try again in a minute.")
				return
			end
			-- mutate profile.data freely; it auto-saves
		end)

		Players.PlayerRemoving:Connect(function(player)
			store:Release(player.UserId)
		end)
--]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local DEFAULT_AUTO_SAVE_INTERVAL = 60
local DEFAULT_RETRY_COUNT = 5
local DEFAULT_RETRY_BASE_DELAY = 1
local SESSION_STEAL_THRESHOLD = 300
local SHUTDOWN_FLUSH_TIMEOUT = 30

local SERVER_ID = HttpService:GenerateGUID(false)

local activeStores = {} -- weak-ish list of all stores so BindToClose can flush

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end

-- Fill missing keys in `data` from `template` recursively. Does not overwrite
-- existing keys, even if their type disagrees with the template — assume the
-- migrate hook handles intentional shape changes.
local function reconcile(data, template)
	if type(template) ~= "table" then
		return
	end
	for key, value in pairs(template) do
		if data[key] == nil then
			data[key] = deepCopy(value)
		elseif type(data[key]) == "table" and type(value) == "table" then
			reconcile(data[key], value)
		end
	end
end

-- Run `fn` up to `maxAttempts` times, doubling the delay between tries.
-- Returns (true, result) on success or (false, lastError) after all attempts fail.
local function retry(maxAttempts, baseDelay, fn)
	local lastError
	for attempt = 1, maxAttempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < maxAttempts then
			task.wait(baseDelay * 2 ^ (attempt - 1))
		end
	end
	return false, lastError
end

--------------------------------------------------------------------------------
-- Profile
--------------------------------------------------------------------------------

local Profile = {}
Profile.__index = Profile

function Profile:_writeBack(releaseSession)
	local store = self._store
	local now = os.time()
	local ok, err = retry(store._retryCount, store._retryBaseDelay, function()
		return store._dataStore:UpdateAsync(self._key, function(latest)
			latest = latest or {}
			if latest.session and latest.session.serverId ~= SERVER_ID then
				local age = now - (latest.session.refreshedAt or 0)
				if age < SESSION_STEAL_THRESHOLD then
					-- Lost our lock somehow; abort write.
					return nil
				end
			end
			latest.data = self.data
			latest.version = store._schemaVersion
			if releaseSession then
				latest.session = nil
			else
				latest.session = { serverId = SERVER_ID, refreshedAt = now }
			end
			return latest
		end)
	end)
	self._lastSavedAt = os.clock()
	if not ok then
		warn(("[DataStoreSafe] Save failed for %s/%s: %s"):format(
			store._name, tostring(self.userId), tostring(err)))
		return false
	end
	return true
end

function Profile:Save()
	if self._released then
		return false
	end
	return self:_writeBack(false)
end

function Profile:_startHeartbeat()
	task.spawn(function()
		while not self._released do
			task.wait(self._store._autoSaveInterval)
			if self._released then
				break
			end
			self:_writeBack(false)
		end
	end)
end

--------------------------------------------------------------------------------
-- DataStoreSafe
--------------------------------------------------------------------------------

local DataStoreSafe = {}
DataStoreSafe.__index = DataStoreSafe

function DataStoreSafe.new(name, options)
	assert(type(name) == "string" and #name > 0, "DataStoreSafe.new: name is required")
	options = options or {}
	local self = setmetatable({
		_name = name,
		_dataStore = DataStoreService:GetDataStore(name),
		_template = options.template or {},
		-- Clamped so the heartbeat refreshes the session before the steal threshold elapses.
		_autoSaveInterval = math.clamp(
			options.autoSaveInterval or DEFAULT_AUTO_SAVE_INTERVAL,
			5,
			SESSION_STEAL_THRESHOLD - 30
		),
		_retryCount = options.retryCount or DEFAULT_RETRY_COUNT,
		_retryBaseDelay = options.retryBaseDelay or DEFAULT_RETRY_BASE_DELAY,
		_schemaVersion = options.schemaVersion or 1,
		_migrate = options.migrate,
		_profiles = {},
	}, DataStoreSafe)
	table.insert(activeStores, self)
	return self
end

function DataStoreSafe:_keyFor(userId)
	return "user_" .. tostring(userId)
end

function DataStoreSafe:Get(userId)
	return self._profiles[userId]
end

function DataStoreSafe:Load(userId)
	if self._profiles[userId] then
		return self._profiles[userId]
	end

	local key = self:_keyFor(userId)

	-- Atomically claim the session and read the stored payload in one round-trip.
	local claimOk, claimResult = retry(self._retryCount, self._retryBaseDelay, function()
		return self._dataStore:UpdateAsync(key, function(latest)
			latest = latest or {}
			local now = os.time()
			if latest.session and latest.session.serverId ~= SERVER_ID then
				local age = now - (latest.session.refreshedAt or 0)
				if age < SESSION_STEAL_THRESHOLD then
					return nil -- another server still owns this key
				end
				-- Lock is stale; we steal it.
			end
			latest.session = { serverId = SERVER_ID, refreshedAt = now }
			return latest
		end)
	end)

	if not claimOk then
		warn(("[DataStoreSafe] Load failed for %s/%s: %s"):format(
			self._name, tostring(userId), tostring(claimResult)))
		return nil
	end
	if claimResult == nil then
		warn(("[DataStoreSafe] Session held by another server for %s/%s"):format(
			self._name, tostring(userId)))
		return nil
	end

	-- Resolve the actual user data, running migrations if the saved schema
	-- version differs from the current one.
	local data
	if claimResult.data then
		data = claimResult.data
		local savedVersion = claimResult.version or 1
		if savedVersion ~= self._schemaVersion and self._migrate then
			local ok, migrated = pcall(self._migrate, data, savedVersion, self._schemaVersion)
			if ok and type(migrated) == "table" then
				data = migrated
			elseif not ok then
				warn(("[DataStoreSafe] Migration error for %s/%s: %s"):format(
					self._name, tostring(userId), tostring(migrated)))
			end
		end
	else
		data = deepCopy(self._template)
	end

	reconcile(data, self._template)

	local profile = setmetatable({
		userId = userId,
		data = data,
		_store = self,
		_key = key,
		_released = false,
		_lastSavedAt = os.clock(),
	}, Profile)

	self._profiles[userId] = profile
	profile:_startHeartbeat()
	return profile
end

function DataStoreSafe:Release(userId)
	local profile = self._profiles[userId]
	if not profile then
		return
	end
	profile._released = true
	profile:_writeBack(true)
	self._profiles[userId] = nil
end

function DataStoreSafe:ReleaseAll()
	for userId in pairs(self._profiles) do
		self:Release(userId)
	end
end

--------------------------------------------------------------------------------
-- Shutdown flush
--------------------------------------------------------------------------------

game:BindToClose(function()
	local pending = {}
	for _, store in ipairs(activeStores) do
		for userId in pairs(store._profiles) do
			local thread = task.spawn(function()
				store:Release(userId)
			end)
			table.insert(pending, thread)
		end
	end

	local deadline = os.clock() + SHUTDOWN_FLUSH_TIMEOUT
	while os.clock() < deadline do
		local stillRunning = false
		for _, t in ipairs(pending) do
			if coroutine.status(t) ~= "dead" then
				stillRunning = true
				break
			end
		end
		if not stillRunning then
			break
		end
		task.wait(0.2)
	end
end)

return DataStoreSafe
