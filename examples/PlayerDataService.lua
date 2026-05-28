--[[
	Example: a tiny PlayerDataService built on DataStoreSafe.

	Drop this into ServerScriptService alongside DataStoreSafe. It loads each
	player's profile on join, mutates it during the session, and releases it
	on leave or shutdown.
--]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local DataStoreSafe = require(ServerStorage:WaitForChild("DataStoreSafe"))

local store = DataStoreSafe.new("PlayerData_v1", {
	template = {
		coins = 0,
		level = 1,
		xp = 0,
		inventory = {},
		settings = {
			music = true,
			sfx = true,
		},
	},
	autoSaveInterval = 60,
	schemaVersion = 2,
	migrate = function(data, fromVersion, toVersion)
		-- v1 stored xp as `experience`. v2 renames it.
		if fromVersion == 1 and toVersion >= 2 then
			data.xp = data.experience or 0
			data.experience = nil
		end
		return data
	end,
})

local PlayerDataService = {}

function PlayerDataService:Get(player)
	return store:Get(player.UserId)
end

function PlayerDataService:AddCoins(player, amount)
	local profile = store:Get(player.UserId)
	if not profile then
		return
	end
	profile.data.coins = profile.data.coins + amount
end

Players.PlayerAdded:Connect(function(player)
	local profile = store:Load(player.UserId)
	if not profile then
		player:Kick("Could not load your save — please rejoin in a minute.")
		return
	end
	-- Hook into your gameplay systems here.
end)

Players.PlayerRemoving:Connect(function(player)
	store:Release(player.UserId)
end)

return PlayerDataService
