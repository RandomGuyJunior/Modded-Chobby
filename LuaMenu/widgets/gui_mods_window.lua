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
local STATE_PATH = "LuaUI/Config/randomguy_mods_state.json"
local BASE_GAME_TAG = "randomguy-hosting:test"
local STACK_ROOT = "games/"

local ModsWindow = {}
local window
local listPanel
local statusLabel
local mods = {}
local installing = {}
local downloadErrors = {}
local enabledState = {}
local installedState = {}
local installedVersions = {}
local updateChecks = {}
local pendingUninstall = {}
local uninstallErrors = {}
local uninstallSerial = 0
local refreshList
local stateNeedsMigration = false
local generatedGameName

local function ensureDirectories()
	Spring.CreateDir("LuaUI/Config")
	Spring.CreateDir(STACK_ROOT)
end

local function readFile(path)
	local content = VFS.LoadFile(path)
	if content then return content end
	local f = io.open(path, "rb")
	if not f then return nil end
	content = f:read("*all")
	f:close()
	return content
end

local function writeFile(path, content)
	local f, err = io.open(path, "wb")
	if not f then
		Spring.Echo("[ModsWindow] Could not write " .. path .. ": " .. tostring(err))
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function isInstalled(entry)
	if not entry or not entry.rapid_tag then return false end
	local id = entry.id or entry.rapid_tag
	return installedState[id] == true
end

local function loadState()
	local content = readFile(STATE_PATH)
	if not content or content == "" then return end
	local ok, data = pcall(function() return json.decode(content) end)
	if ok and type(data) == "table" then
		if type(data.enabled) == "table" then enabledState = data.enabled end
		if type(data.versions) == "table" then installedVersions = data.versions end
		if type(data.installed) == "table" then
			installedState = data.installed
		else
			-- State files created before Mod Hub tracked installation explicitly.
			-- Migrate only known entries after the catalog is loaded.
			stateNeedsMigration = true
		end
	end
end

local function saveState()
	ensureDirectories()
	local ok, encoded = pcall(function()
		return json.encode({schema_version = 1, installed = installedState, enabled = enabledState, versions = installedVersions})
	end)
	if ok then
		writeFile(STATE_PATH, encoded)
	end
end

local function archiveVersion(entry)
	if not entry or not entry.rapid_tag or not VFS.GetNameFromRapidTag then return nil end
	local name = VFS.GetNameFromRapidTag(entry.rapid_tag)
	if name and name ~= "" and VFS.HasArchive(name) then return name end
	return nil
end

local function isEnabled(entry)
	if not isInstalled(entry) then return false end
	local id = entry.id or entry.rapid_tag
	if enabledState[id] == nil then
		return true -- installed mods are active by default
	end
	return enabledState[id] ~= false
end

local function getEnabledMods()
	local result = {}
	for _, entry in ipairs(mods) do
		if entry.enabled ~= false and entry.rapid_tag and isEnabled(entry) then
			result[#result + 1] = entry
		end
	end
	return result
end

local function makeStackKey(active)
	local parts = {}
	for _, entry in ipairs(active) do
		local id = tostring(entry.id or entry.rapid_tag or "mod")
		id = id:gsub("[^%w_%-]", "_")
		parts[#parts + 1] = id
	end
	return table.concat(parts, "__")
end

local function rebuildSkirmishStack()
	local active = getEnabledMods()
	if #active == 0 then
		generatedGameName = nil
		return
	end

	ensureDirectories()
	local key = makeStackKey(active)
	local stackName = "RandomGuy Mod Stack " .. key
	local stackDir = STACK_ROOT .. "randomguy_mod_stack_" .. key .. ".sdd"
	Spring.CreateDir(stackDir)

	-- Resolve Rapid tags against Recoil's installed archive index. A mod stack
	-- must depend on archive identities, not tags used by the downloader.
	local function installedArchive(tag)
		local name = VFS.GetNameFromRapidTag and VFS.GetNameFromRapidTag(tag)
		if not name or name == "" or not VFS.HasArchive(name) then
			Spring.Echo("[ModsWindow] Cannot build Skirmish stack: installed archive unresolved for " .. tag)
			return nil
		end
		return name
	end

	local foundation = installedArchive(BASE_GAME_TAG)
	if not foundation then
		generatedGameName = nil
		return
	end
	local dependencies = {string.format("%q", foundation)}
	for _, entry in ipairs(active) do
		local archive = installedArchive(entry.rapid_tag)
		if not archive then
			generatedGameName = nil
			return
		end
		dependencies[#dependencies + 1] = string.format("%q", archive)
	end
	Spring.Echo("[ModsWindow] Skirmish installed archive dependencies: " .. table.concat(dependencies, ", "))

	local modinfo = table.concat({
		"return {",
		'\tname = "' .. stackName .. '",',
		'\tdescription = "RandomGuy local skirmish mod stack",',
		'\tshortname = "RGMODSTACK",',
		'\tmutator = "RandomGuy Mod Stack",',
		'\tgame = "Beyond All Reason",',
		'\tshortGame = "BYAR",',
		"\tmodtype = 1,",
		"\tdepend = {",
		"\t\t" .. table.concat(dependencies, ",\n\t\t"),
		"\t},",
		"}",
		"",
	}, "\n")

	if not writeFile(stackDir .. "/modinfo.lua", modinfo) then
		generatedGameName = nil
		return
	end

	-- Chobby's modoptions panel uses VFS.UseArchive(gameName), which mounts
	-- only the selected archive, not its dependency closure. Expose the
	-- foundation's modoptions in the local stack for that preview mount.
	local optionsContent = VFS.UseArchive(foundation, function()
		return VFS.LoadFile("modoptions.lua", VFS.ZIP)
	end)
	if not optionsContent then
		Spring.Echo("[ModsWindow] Cannot read RandomGuy Hosting modoptions.lua from " .. foundation)
		generatedGameName = nil
		return
	end
	if not writeFile(stackDir .. "/modoptions.lua", optionsContent) then
		generatedGameName = nil
		return
	end

	generatedGameName = stackName
	Spring.Echo("[ModsWindow] Skirmish mod stack: " .. stackName)
end

local function uninstallMod(entry)
	local id = entry.id or entry.rapid_tag
	if not isInstalled(entry) or installing[id] or pendingUninstall[id] then return end
	if not (WG.Connector and WG.Connector.enabled and WG.Connector.Send) then
		uninstallErrors[id] = "Launcher connection unavailable; no files were removed."
		refreshList()
		return
	end
	uninstallSerial = uninstallSerial + 1
	local requestId = tostring(os.time()) .. "-" .. tostring(uninstallSerial)
	pendingUninstall[id] = requestId
	uninstallErrors[id] = nil
	WG.Connector.Send("UninstallMod", {id = id, tag = entry.rapid_tag, requestId = requestId})
	refreshList()
end

local function onUninstallResult(command)
	if type(command) ~= "table" then return end
	local id = command.id
	if not id or not pendingUninstall[id] or pendingUninstall[id] ~= command.requestId then return end
	pendingUninstall[id] = nil
	if command.success == true then
		installedState[id] = nil
		enabledState[id] = nil
		installedVersions[id] = nil
		updateChecks[id] = nil
		downloadErrors[id] = nil
		uninstallErrors[id] = nil
		saveState()
		rebuildSkirmishStack()
	else
		uninstallErrors[id] = tostring(command.error or "Uninstall failed; files were not removed.")
		Spring.Echo("[ModsWindow] " .. uninstallErrors[id])
	end
	refreshList()
end

local function clearList()
	if listPanel then listPanel:ClearChildren() end
end

refreshList = function()
	clearList()
	if not listPanel then return end
	local visible, active = 0, 0
	for _, entry in ipairs(mods) do
		if entry.enabled ~= false and entry.rapid_tag and entry.rapid_tag:match("^dev%-mods:[%w_%-]+$") then
			visible = visible + 1
			local installed = isInstalled(entry)
			local enabled = installed and isEnabled(entry)
			if enabled then active = active + 1 end
			local id = entry.id or entry.rapid_tag or "unknown"
			local title = entry.name or id
			local description = entry.description or ""
			local version = installedVersions[id] or archiveVersion(entry)
			if updateChecks[id] then description = description .. "\nChecking for updates..." end
			if downloadErrors[id] then description = description .. "\nDownload failed: " .. downloadErrors[id] end
			local author = entry.author and ("By " .. entry.author) or ""

			local card = Panel:New {
				width = "100%", height = 122, padding = {12, 10, 12, 10},
				borderColor = {0.48, 0.55, 0.65, 1},
				backgroundColor = {0.12, 0.14, 0.18, 0.85},
			}
			Label:New {
				parent = card, x = 12, y = 8, right = 150, height = 25,
				caption = title, align = "left", font = {size = 18},
			}
			Label:New {
				parent = card, x = 12, y = 34, right = installed and 280 or 150, height = 20,
				caption = author, align = "left",
				font = {size = 13, color = {0.75, 0.75, 0.75, 1}},
			}
			Label:New {
				parent = card, x = 12, y = 58, right = installed and 280 or 150, bottom = 8,
				caption = description .. "\nInstalled build: " .. tostring(version or "Unknown"),
				align = "left", valign = "top", font = {size = 13},
			}

			local button
			button = Button:New {
				parent = card, right = 12, y = 36, width = 125, height = 42,
				caption = installed and (enabled and "Enabled" or "Disabled")
					or (installing[id] and "Installing..." or "Install"),
				backgroundColor = installed
					and (enabled and {0.16, 0.48, 0.22, 0.95} or {0.57, 0.17, 0.17, 0.95})
					or {0.20, 0.24, 0.30, 0.95},
				enabled = (not installing[id]) and (not pendingUninstall[id]),
				OnClick = {
					function()
						if isInstalled(entry) then
							enabledState[id] = not isEnabled(entry)
							saveState()
							rebuildSkirmishStack()
							refreshList()
							return
						end
						if installing[id] then return end
						if not (entry.rapid_tag and entry.rapid_tag:match("^dev%-mods:[%w_%-]+$")) then
							Spring.Echo("[ModsWindow] Invalid catalog entry: " .. tostring(id))
							return
						end
						if not (WG.DownloadHandler and WG.DownloadHandler.QueueDownload) then
							Spring.Echo("[ModsWindow] DownloadHandler unavailable")
							return
						end
						downloadErrors[id] = nil
						installing[id] = entry
						button:SetCaption("Installing...")
						button.enabled = false
						button:Invalidate()
						WG.DownloadHandler.QueueDownload(
							entry.rapid_tag, "game", -1, 0,
							{modId = id}
						)
						Spring.Echo("[ModsWindow] Installing trusted Rapid mod " .. entry.rapid_tag)
					end
				},
			}
			if installed then
				Button:New {
					parent = card, right = 12, y = 36, width = 120, height = 42,
					caption = "Uninstall",
					backgroundColor = {0.45, 0.18, 0.18, 0.95},
					enabled = not installing[id] and not pendingUninstall[id],
					OnClick = {function() uninstallMod(entry) end},
				}
			end
			listPanel:AddChild(card)
		end
	end

	-- ScrollPanel clips children to the StackPanel bounds. Give the stack an
	-- explicit content height so added cards are actually visible and scrollable.
	listPanel:SetPos(nil, nil, nil, math.max(1, visible * 130))
	listPanel:Invalidate()

	if statusLabel then
		if visible == 0 then
			statusLabel:SetCaption("No mods are published in the DevelopmentEnvironment catalog yet.")
		else
			statusLabel:SetCaption("Discovered " .. visible .. " mod(s). " .. active .. " active in Skirmish.")
		end
	end
end

local function checkInstalledUpdates()
	if not (WG.DownloadHandler and WG.DownloadHandler.QueueDownload) then return end
	for _, entry in ipairs(mods) do
		local id = entry.id or entry.rapid_tag
		if entry.enabled ~= false and entry.rapid_tag and isInstalled(entry) and not installing[id] and not updateChecks[id] then
			-- Rapid tags are moving targets. Re-requesting an installed tag lets
			-- pr-downloader compare the remote package and fetch only changes.
			-- The archive name is the installed build identity, not catalog text.
			updateChecks[id] = {entry = entry, before = archiveVersion(entry)}
			WG.DownloadHandler.QueueDownload(entry.rapid_tag, "game", -1, 0, {modId = id, updateCheck = true})
			Spring.Echo("[ModsWindow] Checking Rapid update for " .. entry.rapid_tag)
		end
	end
end

local function parseCatalog(content)
	if not content or content == "" then return false, "empty catalog" end
	local ok, data = pcall(function() return json.decode(content) end)
	if not ok or type(data) ~= "table" then return false, "invalid JSON" end
	if tonumber(data.schema_version) ~= 1 or type(data.mods) ~= "table" then
		return false, "unsupported catalog schema"
	end
	mods = data.mods
	if stateNeedsMigration then
		for _, entry in ipairs(mods) do
			local id = entry.id or entry.rapid_tag
			-- Old state only contained entries the user had interacted with.
			-- Preserve those known Mod Hub installs without scanning the filesystem.
			if id and enabledState[id] ~= nil then
				installedState[id] = true
			end
		end
		stateNeedsMigration = false
		saveState()
	end
	rebuildSkirmishStack()
	refreshList()
	checkInstalledUpdates()
	return true
end

local function loadCatalogFromDisk()
	local content = readFile(CATALOG_PATH)
	if not content then return false end
	local ok, err = parseCatalog(content)
	if not ok then Spring.Echo("[ModsWindow] " .. tostring(err)) end
	return ok
end

local function fetchCatalog()
	ensureDirectories()
	if statusLabel then statusLabel:SetCaption("Refreshing mod catalog...") end
	if WG.DownloadHandler and WG.DownloadHandler.QueueDownload then
		WG.DownloadHandler.QueueDownload(
			CATALOG_DOWNLOAD, "resource", -1, 0,
			{
				url = CATALOG_URL .. "?t=" .. os.time(),
				destination = CATALOG_PATH,
				extract = false,
				overwrite = true,
				hidden = true,
			}
		)
	elseif statusLabel then
		statusLabel:SetCaption("DownloadHandler unavailable.")
	end
end

local function onDownloadFinished(_, _, name, fileType)
	if name == CATALOG_DOWNLOAD then
		if not loadCatalogFromDisk() and statusLabel then
			statusLabel:SetCaption("Could not read mod catalog.")
		end
		return
	end

	if fileType == "game" or fileType == "RAPID" then
		local completedId
		local isUpdateCheck = false
		for id, check in pairs(updateChecks) do
			if name == id or name == check.entry.rapid_tag then
				if pendingUninstall[id] then updateChecks[id] = nil return end
				completedId = id
				isUpdateCheck = true
				break
			end
		end
		for id, entry in pairs(installing) do
			if name == id or (type(entry) == "table" and name == entry.rapid_tag) then
				completedId = id
				break
			end
		end
		-- Older DownloadHandler callbacks may not preserve our mod id/tag. If
		-- exactly one Mod Hub install is pending, that game completion is it.
		if not completedId then
			local onlyId
			for id in pairs(installing) do
				if onlyId then onlyId = nil break end
				onlyId = id
			end
			completedId = onlyId
		end
		if completedId and not pendingUninstall[completedId] then
			downloadErrors[completedId] = nil
			installedState[completedId] = true
			local check = updateChecks[completedId]
			if check then
				local after = archiveVersion(check.entry)
				if after and check.before ~= after then Spring.Echo("[ModsWindow] Rapid mod updated: " .. after) end
				if after then installedVersions[completedId] = after end
				updateChecks[completedId] = nil
			else
				enabledState[completedId] = true
				local entry = installing[completedId]
				if entry then installedVersions[completedId] = archiveVersion(entry) end
				installing[completedId] = nil
			end
		end
		saveState()
		rebuildSkirmishStack()
		refreshList()
	end
end

local function onDownloadFailed(_, _, reason, name, fileType)
	if name == CATALOG_DOWNLOAD then
		if statusLabel then statusLabel:SetCaption("Failed to download mod catalog.") end
		return
	end
	if fileType ~= "game" and fileType ~= "RAPID" then return end
	for id, check in pairs(updateChecks) do
		if name == id or name == check.entry.rapid_tag then
			updateChecks[id] = nil
			downloadErrors[id] = "Update check failed: " .. tostring(reason or "unknown error")
			refreshList()
			return
		end
	end
	for id, entry in pairs(installing) do
		if name == entry.rapid_tag then
			installing[id] = nil
			downloadErrors[id] = tostring(reason or "unknown error")
			Spring.Echo("[ModsWindow] Download failed for " .. tostring(name) .. ": " .. downloadErrors[id] .. ". Check launcher log for pr-downloader details.")
			refreshList()
			return
		end
	end
end

function ModsWindow.GetSkirmishGameName()
	return generatedGameName
end

function ModsWindow.GetEnabledMods()
	return getEnabledMods()
end

function ModsWindow.GetControl()
	if window then return window end
	window = Control:New {
		name = "mods", x = 0, y = 0, right = 0, bottom = 0, padding = {8, 8, 8, 8},
	}
	Label:New {
		parent = window, x = 12, y = 8, width = 300, height = 32,
		caption = "Mods", align = "left", font = {size = 24},
	}
	Button:New {
		parent = window, right = 12, y = 8, width = 110, height = 32,
		caption = "Refresh", OnClick = {fetchCatalog},
	}
	statusLabel = Label:New {
		parent = window, x = 12, y = 44, right = 12, height = 24,
		caption = "Loading mod catalog...", align = "left",
		font = {size = 13, color = {0.75, 0.75, 0.75, 1}},
	}
	local scroll = ScrollPanel:New {
		parent = window, x = 8, y = 72, right = 8, bottom = 8, horizontalScrollbar = false,
	}
	listPanel = StackPanel:New {
		parent = scroll, x = 0, y = 0, right = 0, height = 1,
		resizeItems = false, itemMargin = {0, 0, 0, 8},
		itemPadding = {0, 0, 0, 0}, orientation = "vertical",
	}
	if not loadCatalogFromDisk() then fetchCatalog() else fetchCatalog() end
	return window
end

function widget:Initialize()
	VFS.Include(
		LUA_DIRNAME .. "widgets/chobby/headers/exports.lua",
		nil,
		VFS.RAW_FIRST
	)
	ensureDirectories()
	loadState()
	-- Load the cached catalog during initialization so local Skirmish can use
	-- the active mod stack even if the Mods page has not been opened this run.
	loadCatalogFromDisk()
	WG.ModsWindow = ModsWindow
	if WG.Connector and WG.Connector.Register then WG.Connector.Register('UninstallModResult', onUninstallResult) end
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
