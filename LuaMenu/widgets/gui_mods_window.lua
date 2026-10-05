function widget:GetInfo()
	return {
		name      = "Mods Window",
		author    = "RandomGuyJunior",
		date      = "Oct 2026",
		license   = "GNU GPL, v2 or later",
		layer     = -100001,
		enabled   = true,
	}
end

local json = json or (VFS.Include and VFS.Include("libs/json.lua"))

local CATALOG_URL = "https://raw.githubusercontent.com/RandomGuyJunior/DevelopmentEnvironment/main/mods.json"
local CATALOG_PATH = "LuaUI/Config/randomguy_mods_catalog.json"
local CATALOG_DOWNLOAD = "randomguy_mod_catalog"

local ModsWindow = {}
local window
local listPanel
local statusLabel
local mods = {}
local installing = {}

local function ensureCatalogDirectory()
	Spring.CreateDir("LuaUI/Config")
end

local function isInstalled(entry)
	if not entry or not entry.rapid_tag then
		return false
	end
	if VFS.GetNameFromRapidTag then
		local resolved = VFS.GetNameFromRapidTag(entry.rapid_tag)
		if resolved and resolved ~= "" then
			return true
		end
	end
	return false
end

local function clearList()
	if listPanel then
		listPanel:ClearChildren()
	end
end

local function addModCard(entry)
	local installed = isInstalled(entry)
	local id = entry.id or entry.rapid_tag or "unknown"
	local title = entry.name or id
	local description = entry.description or ""
	local author = entry.author and ("By " .. entry.author) or ""
	local rapidTag = entry.rapid_tag or ""

	local card = Control:New {
		width = "100%",
		height = 122,
		padding = {12, 10, 12, 10},
	}

	Label:New {
		parent = card,
		x = 12,
		y = 8,
		right = 150,
		height = 25,
		caption = title,
		align = "left",
		font = {size = 18},
	}

	Label:New {
		parent = card,
		x = 12,
		y = 34,
		right = 150,
		height = 20,
		caption = author,
		align = "left",
		font = {size = 13, color = {0.75, 0.75, 0.75, 1}},
	}

	Label:New {
		parent = card,
		x = 12,
		y = 58,
		right = 150,
		bottom = 8,
		caption = description .. "\nRapid: " .. rapidTag,
		align = "left",
		valign = "top",
		font = {size = 13},
	}

	local button
	button = Button:New {
		parent = card,
		right = 12,
		y = 36,
		width = 125,
		height = 42,
		caption = installed and "Installed" or (installing[id] and "Installing..." or "Install"),
		enabled = not installed and not installing[id],
		OnClick = {
			function()
				if installing[id] or isInstalled(entry) then return end
				if not (entry.rapid_tag and entry.rapid_repo) then
					Spring.Echo("[ModsWindow] Invalid catalog entry: " .. tostring(id))
					return
				end
				if not (WG.DownloadHandler and WG.DownloadHandler.QueueDownload) then
					Spring.Echo("[ModsWindow] DownloadHandler unavailable")
					return
				end

				installing[id] = true
				button:SetCaption("Installing...")
				button.enabled = false
				button:Invalidate()

				WG.DownloadHandler.QueueDownload(
					entry.rapid_tag,
					"game",
					-1,
					0,
					{
						rapidRepo = entry.rapid_repo,
						modId = id,
					}
				)
				Spring.Echo("[ModsWindow] Installing " .. entry.rapid_tag .. " from " .. entry.rapid_repo)
			end
		},
	}

	listPanel:AddChild(card)
end

local function refreshList()
	clearList()
	local visible = 0
	for _, entry in ipairs(mods) do
		if entry.enabled ~= false and entry.rapid_tag and entry.rapid_repo then
			visible = visible + 1
			addModCard(entry)
		end
	end

	if statusLabel then
		if visible == 0 then
			statusLabel:SetCaption("No mods are published in the DevelopmentEnvironment catalog yet.")
		else
			statusLabel:SetCaption("Discovered " .. visible .. " mod(s).")
		end
	end
end

local function parseCatalog(content)
	if not content or content == "" then
		return false, "empty catalog"
	end
	local ok, data = pcall(function() return json.decode(content) end)
	if not ok or type(data) ~= "table" then
		return false, "invalid JSON"
	end
	if tonumber(data.schema_version) ~= 1 or type(data.mods) ~= "table" then
		return false, "unsupported catalog schema"
	end
	mods = data.mods
	refreshList()
	return true
end

local function loadCatalogFromDisk()
	local content = VFS.LoadFile(CATALOG_PATH)
	if not content then
		local f = io.open(CATALOG_PATH, "rb")
		if f then
			content = f:read("*all")
			f:close()
		end
	end
	if not content then return false end
	local ok, err = parseCatalog(content)
	if not ok then
		Spring.Echo("[ModsWindow] " .. tostring(err))
	end
	return ok
end

local function fetchCatalog()
	ensureCatalogDirectory()
	if statusLabel then
		statusLabel:SetCaption("Refreshing mod catalog...")
	end

	if WG.DownloadHandler and WG.DownloadHandler.QueueDownload then
		WG.DownloadHandler.QueueDownload(
			CATALOG_DOWNLOAD,
			"resource",
			-1,
			0,
			{
				url = CATALOG_URL .. "?t=" .. os.time(),
				destination = CATALOG_PATH,
				extract = false,
				hidden = true,
			}
		)
	else
		if statusLabel then
			statusLabel:SetCaption("DownloadHandler unavailable.")
		end
	end
end

local function onDownloadFinished(_, name, fileType)
	if name == CATALOG_DOWNLOAD then
		if not loadCatalogFromDisk() and statusLabel then
			statusLabel:SetCaption("Could not read mod catalog.")
		end
		return
	end

	if fileType == "game" or fileType == "RAPID" then
		for id in pairs(installing) do
			installing[id] = nil
		end
		refreshList()
	end
end

local function onDownloadFailed(_, _, name)
	if name == CATALOG_DOWNLOAD then
		if statusLabel then
			statusLabel:SetCaption("Failed to download mod catalog.")
		end
		return
	end

	for id in pairs(installing) do
		installing[id] = nil
	end
	refreshList()
end

function ModsWindow.GetControl()
	if window then return window end

	window = Control:New {
		name = "mods",
		x = 0,
		y = 0,
		right = 0,
		bottom = 0,
		padding = {8, 8, 8, 8},
	}

	Label:New {
		parent = window,
		x = 12,
		y = 8,
		width = 300,
		height = 32,
		caption = "Mods",
		align = "left",
		font = {size = 24},
	}

	Button:New {
		parent = window,
		right = 12,
		y = 8,
		width = 110,
		height = 32,
		caption = "Refresh",
		OnClick = {fetchCatalog},
	}

	statusLabel = Label:New {
		parent = window,
		x = 12,
		y = 44,
		right = 12,
		height = 24,
		caption = "Loading mod catalog...",
		align = "left",
		font = {size = 13, color = {0.75, 0.75, 0.75, 1}},
	}

	local scroll = ScrollPanel:New {
		parent = window,
		x = 8,
		y = 72,
		right = 8,
		bottom = 8,
		horizontalScrollbar = false,
	}

	listPanel = StackPanel:New {
		parent = scroll,
		x = 0,
		y = 0,
		right = 0,
		resizeItems = false,
		itemMargin = {0, 0, 0, 8},
		itemPadding = {0, 0, 0, 0},
		orientation = "vertical",
	}

	if not loadCatalogFromDisk() then
		fetchCatalog()
	else
		-- Always refresh in the background so discovery follows the repo.
		fetchCatalog()
	end

	return window
end

function widget:Initialize()
	WG.ModsWindow = ModsWindow
	if WG.DownloadHandler and WG.DownloadHandler.AddListener then
		WG.DownloadHandler.AddListener("DownloadFinished", onDownloadFinished)
		WG.DownloadHandler.AddListener("DownloadFailed", onDownloadFailed)
	end
end

function widget:Shutdown()
	if WG.DownloadHandler and WG.DownloadHandler.RemoveListener then
		WG.DownloadHandler.RemoveListener("DownloadFinished", onDownloadFinished)
		WG.DownloadHandler.RemoveListener("DownloadFailed", onDownloadFailed)
	end
	WG.ModsWindow = nil
end
