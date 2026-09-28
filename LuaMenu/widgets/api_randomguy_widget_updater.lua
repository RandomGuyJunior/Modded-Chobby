local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "RandomGuy In-Game Widget Updater",
		desc = "Keeps selected BAR LuaUI widgets synced from their upstream GitHub repositories",
		author = "RandomGuyJunior",
		date = "2026-09-28",
		license = "GNU GPL, v2 or later",
		layer = 100000,
		enabled = true,
		handler = true,
	}
end

local widgets = {
	{
		filename = "gui_gridmenu_teamcolor.lua",
		url = "https://raw.githubusercontent.com/Armis71/BAR-Widgets-Public/main/gui_gridmenu_teamcolor.lua",
		marker = 'name = "Grid menu (Team Color)"',
	},
	{
		filename = "gui_info_teamcolor.lua",
		url = "https://raw.githubusercontent.com/Armis71/BAR-Widgets-Public/main/gui_info_teamcolor.lua",
		marker = 'name = "Info (Team Color)"',
	},
}

local installDir = "LuaUI/Widgets/"
local stagingDir = "LuaUI/Widgets/.randomguy_updates/"
local started = false
local pending = {}
local listenerRegistered = false

local function Echo(...)
	Spring.Echo("[RandomGuy Widget Updater]", ...)
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*all")
	f:close()
	return content
end

local function writeFile(path, content)
	local f, err = io.open(path, "wb")
	if not f then
		return false, err
	end
	local ok, writeErr = f:write(content)
	f:close()
	if not ok then
		return false, writeErr
	end
	return true
end

local function installDownloaded(spec, stagingPath)
	local content = readFile(stagingPath)
	if not content then
		Echo("Downloaded file missing:", spec.filename)
		return false
	end

	if not string.find(content, "function widget:GetInfo", 1, true)
		or not string.find(content, spec.marker, 1, true)
	then
		Echo("Refusing invalid upstream file:", spec.filename)
		os.remove(stagingPath)
		return false
	end

	local finalPath = installDir .. spec.filename
	local newPath = finalPath .. ".new"
	local backupPath = finalPath .. ".bak"

	os.remove(newPath)
	local ok, err = writeFile(newPath, content)
	if not ok then
		Echo("Could not stage", spec.filename, tostring(err))
		os.remove(stagingPath)
		return false
	end

	os.remove(backupPath)
	local hadOld = readFile(finalPath) ~= nil
	if hadOld then
		local moved, moveErr = os.rename(finalPath, backupPath)
		if not moved then
			Echo("Could not backup", spec.filename, tostring(moveErr))
			os.remove(newPath)
			os.remove(stagingPath)
			return false
		end
	end

	local moved, moveErr = os.rename(newPath, finalPath)
	if not moved then
		Echo("Could not install", spec.filename, tostring(moveErr))
		if hadOld then
			os.rename(backupPath, finalPath)
		end
		os.remove(newPath)
		os.remove(stagingPath)
		return false
	end

	os.remove(backupPath)
	os.remove(stagingPath)
	Echo("Updated", spec.filename)
	return true
end

local function onDownloadFinished(_, _, name, fileType)
	if fileType ~= "resource" then
		return
	end

	local spec = pending[name]
	if not spec then
		return
	end

	pending[name] = nil
	installDownloaded(spec, name)
end

local function queueUpdates()
	if started then
		return
	end

	if not (WG.DownloadHandler
		and WG.DownloadHandler.QueueDownload
		and WG.DownloadHandler.AddListener)
	then
		return
	end

	started = true

	if not listenerRegistered then
		WG.DownloadHandler.AddListener("DownloadFinished", onDownloadFinished)
		listenerRegistered = true
	end

	for i = 1, #widgets do
		local spec = widgets[i]
		local stagingPath = stagingDir .. spec.filename .. ".download"

		-- The launcher's resource downloader intentionally skips destinations
		-- that already exist, so remove only our disposable staging copy.
		-- The currently installed widget remains untouched until validation
		-- and installation succeed.
		os.remove(stagingPath)
		pending[stagingPath] = spec

		WG.DownloadHandler.QueueDownload(
			stagingPath,
			"resource",
			-1,
			2,
			{
				url = spec.url,
				destination = stagingPath,
				extract = false,
				hidden = true,
			}
		)
	end

	Echo("Checking", #widgets, "upstream widget(s) for updates")
end

function widget:Initialize()
	queueUpdates()
end

function widget:Update()
	if not started then
		queueUpdates()
	end
end

function widget:Shutdown()
	if listenerRegistered and WG.DownloadHandler and WG.DownloadHandler.RemoveListener then
		WG.DownloadHandler.RemoveListener("DownloadFinished", onDownloadFinished)
	end
end
