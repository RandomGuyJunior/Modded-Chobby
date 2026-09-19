function widget:GetInfo()
	return {
		name      = "Modded Map Catalog",
		desc      = "Adds Modded BAR maps to the lobby map catalog",
		author    = "RandomGuy",
		date      = "2026",
		license   = "GNU GPL v2",
		layer     = 0,
		enabled   = true,
	}
end

local MODDED_SERVER = "moddedbar.duckdns.org"
local injected = false

local function IsModdedBAR()
	if not WG.Chobby or not WG.Chobby.Configuration then
		return false
	end

	local address = WG.Chobby.Configuration:GetServerAddress()

	if not address then
		return false
	end

	return string.find(address, MODDED_SERVER, 1, true) ~= nil
end

local function InjectMaps()
	if injected then
		return
	end

	if not IsModdedBAR() then
		return
	end

	if not WG.Chobby.Configuration.gameConfig then
		return
	end

	local mapDetails = WG.Chobby.Configuration.gameConfig.mapDetails

	if not mapDetails then
		return
	end

	mapDetails["Bathtub Brawl V2"] = {
		Width = 16,
		Height = 16,

		Is1v1 = nil,
		IsTeam = 1,
		IsFFA = nil,

		IsCertified = 1,
		IsInPool = 1,

		Special = "Modded",

		Flat = nil,
		Hills = nil,
		Water = nil,

		PlayerCount = "16",
		TeamCount = "2",

		Author = "RandomGuy",
		InfoText = "Custom Modded BAR map.",

		LastUpdate = 1789830000,
	}

	Spring.Echo("MODDED MAP CATALOG: injected Bathtub Brawl V2")

	injected = true
end

function widget:Initialize()
	InjectMaps()
end

function widget:Update()
	if not injected then
		InjectMaps()
	end
end