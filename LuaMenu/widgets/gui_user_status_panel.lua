--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "User status panel",
		desc      = "Displays user status and provides interface for logging out and exiting.",
		author    = "gajop",
		date      = "4 July 2016",
		license   = "GNU LGPL, v2.1 or later",
		layer     = 0,
		enabled   = true  -- loaded by default?
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Chili

local btnLogout
local connectivityText
local connectivityImage
local onlineCountText
local serverCombo
local serverSwitchPending = false
local serverReconnectStarted = false
local startupServerSynced = false
local customServers = {}
local serverEntries = {}
local addServerWindow

local function ParseServerAddress(raw)
    if type(raw) ~= "string" then return nil end
    local host, port = raw:match("^%s*([^:%s/]+):(%d+)%s*$")
    if not host then host = raw:match("^%s*([^:%s/]+)%s*$"); port = "8200" end
    local number = tonumber(port)
    if not host or not host:match("^[%w%.%-]+$") or not number
            or number < 1 or number > 65535 or number % 1 ~= 0 then
        return nil
    end
    return string.lower(host), number
end

local function BuildServerEntries()
    serverEntries = {
        {label = "BAR Official", address = "server4.beyondallreason.info", port = 8200},
        {label = "BAR Modded", address = "moddedbar.duckdns.org", port = 8200},
    }
    for _, server in ipairs(customServers) do
        table.insert(serverEntries, {
            label = server.address .. ":" .. server.port,
            address = server.address, port = server.port,
        })
    end
end

local function RefreshServerCombo()
    if not serverCombo then return end
    BuildServerEntries()
    local items = {}
    for _, entry in ipairs(serverEntries) do table.insert(items, entry.label) end
    table.insert(items, "+ Add TEI server...")
    serverCombo.items = items
    serverCombo:Invalidate()
end

local function SwitchToServer(address, port)
    if not WG.LoginWindowHandler or not WG.LoginWindowHandler.SwitchServer then return end
    serverSwitchPending = true
    serverReconnectStarted = false
    serverCombo:SetEnabled(false)
    WG.LoginWindowHandler.SwitchServer(address, port)
end

local function ShowAddServerPopup()
    if addServerWindow then return end
    local input
    local window = Window:New {
        name = "addTeiServerWindow",
        caption = "Add TEI server",
        x = "30%", y = "30%", width = 430, height = 180,
        resizable = false, draggable = true, parent = screen0,
        children = {},
    }
    addServerWindow = window
    local errorLabel = Label:New {
        parent = window, x = 20, y = 70, right = 20, height = 22,
        caption = "", align = "left",
    }
    Label:New {
        parent = window, x = 20, y = 18, right = 20, height = 22,
        caption = "TEI address (hostname or hostname:port)",
    }
    input = EditBox:New {
        parent = window, x = 20, y = 43, right = 20, height = 28,
        text = "",
    }
    local function Close()
        if addServerWindow then addServerWindow:Dispose(); addServerWindow = nil end
    end
    Button:New {
        parent = window, right = 20, bottom = 12, width = 95, height = 30,
        caption = "Cancel", OnClick = {Close},
    }
    Button:New {
        parent = window, right = 122, bottom = 12, width = 95, height = 30,
        caption = "Connect",
        OnClick = {function()
            local address, port = ParseServerAddress(input.text)
            if not address then
                errorLabel:SetCaption("Enter a valid hostname and optional port (1-65535).")
                return
            end
            local known = false
            for _, entry in ipairs(serverEntries) do
                if entry.address == address and entry.port == port then known = true; break end
            end
            if not known then
                table.insert(customServers, {address = address, port = port})
            end
            RefreshServerCombo()
            Close()
            SwitchToServer(address, port)
        end},
    }
end


local function GetServerSelectionFromAddress(address)
    address = string.lower(tostring(address or ""))
    local port = WG.Chobby.Configuration:GetServerPort()
    for i, entry in ipairs(serverEntries) do
        if entry.address == address and entry.port == port then return i end
    end
    return nil
end

local function SyncServerComboToCurrentServer()
	if not serverCombo
			or not WG.Chobby
			or not WG.Chobby.Configuration then
		return
	end

	local selected =
		GetServerSelectionFromAddress(
			WG.Chobby.Configuration:GetServerAddress()
		)

	if not selected or serverCombo.selected == selected then
		return
	end

	-- Do not call ComboBox:Select here: it fires OnSelect and would
	-- initiate a server switch. This is display-state synchronization only.
	serverCombo.selected = selected
	serverCombo.caption = serverCombo.items[selected]
	serverCombo:Invalidate()
end


local IMAGE_DIR          = LUA_DIRNAME .. "images/"
local IMAGE_ONLINE       = IMAGE_DIR .. "online.png"
local IMAGE_CONNECTING   = IMAGE_DIR .. "connecting.png"
local IMAGE_OFFLINE      = IMAGE_DIR .. "offline.png"

local USER_STATUS_X      = 34
local USER_STATUS_Y      = 52
local USER_STATUS_WIDTH  = 200
local ONLINE_COUNT_GAP   = 10
local ONLINE_COUNT_X     = USER_STATUS_X + USER_STATUS_WIDTH + ONLINE_COUNT_GAP
local ONLINE_COUNT_Y     = 54
local ONLINE_COUNT_UPDATE_INTERVAL = 60

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Lobby listeners

local onAccepted, onDisconnected, onPong, onAddUser, onUserCount

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Initialization

local UserStatusPanel = {}

local function SetOnlineCountVisible(visible)
	if onlineCountText then
		onlineCountText:SetVisibility(visible)
	end
end

local function UpdateOnlineCount()
	if onlineCountText and onlineCountText.parent then
		onlineCountText:SetText(
			"\255\180\180\180" .. lobby:GetUserCount() .. " online\b"
		)
	end
end

local function Logout()
	if lobby:GetConnectionStatus() ~= "offline" then

		if WG.Chobby and WG.Chobby.Configuration then
			WG.Chobby.Configuration:SetConfigValue("autoLogin", false)
		end

		if WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration.gameConfig
				and WG.Chobby.Configuration.gameConfig.logoutOpensLoginPanel then

			WG.LoginWindowHandler.TryLogin()
			--WG.LoginWindowHandler.tabPanel.tabBar:Select("reset")

		else
			Spring.Echo("Logout")

			if WG.Chobby and WG.Chobby.interfaceRoot then
				WG.Chobby.interfaceRoot.CleanMultiplayerState()
			end

			lobby:Disconnect()
		end

	else
		Spring.Echo("Login")
		WG.LoginWindowHandler.TryLogin()
	end
end

local function GoToProfilePage()
	if WG.Chobby and WG.Chobby.Configuration then
		local Configuration = WG.Chobby.Configuration

		if Configuration.gameConfig.link_homePage ~= nil then
			WG.BrowserHandler.OpenUrl(
				Configuration.gameConfig.link_homePage()
			)
		end
	end
end

local function ShowKeys()
	WG.KeysPanel.Show()
end

local function Quit()
	Spring.Echo("Quitting...")
	Spring.Quit()
end

-- local function UpdateLatency()
-- 	local latency = lobby:GetLatency()
-- 	local color
--
-- 	latency = math.ceil(latency)
--
-- 	if latency < 500 then
-- 		color = WG.Chobby.Configuration:GetSuccessColor()
-- 	elseif latency < 1000 then
-- 		color = WG.Chobby.Configuration:GetWarningColor()
-- 	else
-- 		if latency > 9000 then
-- 			latency = "9000+"
-- 		end
-- 		color = "\255\255\125\0"
-- 	end
--
-- 	connectivityText:SetCaption(color .. latency .. "ms\b")
-- end
--
-- local _lastUpdate = os.clock()
--
-- function widget:Update()
-- 	if os.clock() - _lastUpdate > 1 then
-- 		_lastUpdate = os.clock()
-- 		UpdateLatency()
-- 	end
-- end

local function InitializeControls(window)
	local menuX = 0

	-------------------------------------------------------------------
	-- Login / Logout
	-------------------------------------------------------------------

	menuX = menuX + 3

	btnLogout = Button:New {
		y = 2,
		right = menuX,
		width = 108,
		height = 38,
		caption = i18n("login"),
		parent = window,
		objectOverrideFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(2))
			or nil,

		OnClick = {
			Logout
		}
	}

	menuX = menuX + 108

	-------------------------------------------------------------------
	-- Home
	-------------------------------------------------------------------

	if WG.Chobby
			and WG.Chobby.Configuration
			and WG.Chobby.Configuration.gameConfig
			and WG.Chobby.Configuration.gameConfig.link_homePage ~= nil then

		menuX = menuX + 3

		btnProfile = Button:New {
			y = 2,
			right = menuX,
			width = 108,
			height = 38,
			caption = i18n("home"),
			parent = window,
			objectOverrideFont =
				(WG.Chobby
					and WG.Chobby.Configuration
					and WG.Chobby.Configuration:GetFont(2))
				or nil,

			OnClick = {
				GoToProfilePage
			}
		}

		menuX = menuX + 108
	end

	-------------------------------------------------------------------
	-- Keys
	-------------------------------------------------------------------

	menuX = menuX + 3

	btnKeys = Button:New {
		y = 2,
		right = menuX,
		width = 108,
		height = 38,
		caption = i18n("keys"),
		parent = window,
		objectOverrideFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(2))
			or nil,

		OnClick = {
			ShowKeys
		}
	}

	menuX = menuX + 108

	-------------------------------------------------------------------
	-- Server selector
	-------------------------------------------------------------------

	local currentServerAddress =
		WG.Chobby.Configuration:GetServerAddress()

	local selectedServer =
		GetServerSelectionFromAddress(currentServerAddress)

	menuX = menuX + 3

    BuildServerEntries()
    local items = {}
    for _, entry in ipairs(serverEntries) do table.insert(items, entry.label) end
    table.insert(items, "+ Add TEI server...")
    serverCombo = ComboBox:New {
        y = 2, right = menuX, width = 180, height = 38,
        items = items, selected = selectedServer or 1,
        OnSelect = {function(obj)
            local selection = obj.selected
            if selection == #serverEntries + 1 then
                SyncServerComboToCurrentServer()
                ShowAddServerPopup()
                return
            end
            local entry = serverEntries[selection]
            if not entry then return end
            local Configuration = WG.Chobby.Configuration
            if Configuration:GetServerAddress() ~= entry.address
                    or Configuration:GetServerPort() ~= entry.port then
                SwitchToServer(entry.address, entry.port)
            end
        end},
        parent = window,
        tooltip = "Select a BAR/TEI server or add your own.",
    }

	menuX = menuX + 180

	local serverLabel = Label:New {
		y = 2,
		right = menuX,
		width = 60,
		height = 38,
		caption = "Server:",
		valign = "center",
		align = "right",
		parent = window,
		objectOverrideFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(2))
			or nil,
	}

	menuX = menuX + 60

	-------------------------------------------------------------------
	-- Connection status
	-------------------------------------------------------------------

	connectivityText = TextBox:New {
		name = "connectivityText",
		x = USER_STATUS_X + 2,
		width = 150,
		y = USER_STATUS_Y + 4,
		height = 20,
		valign = "center",
		text = "\255\180\180\180" .. i18n("offline") .. "\b",
		objectOverrideFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(2))
			or nil,

		objectOverrideHintFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(2))
			or nil,

		parent = window,
	}

	onlineCountText = TextBox:New {
		name = "onlineCountText",
		x = ONLINE_COUNT_X,
		width = 110,
		y = ONLINE_COUNT_Y,
		height = 20,
		valign = "center",
		align = "left",
		text =
			"\255\180\180\180"
			.. lobby:GetUserCount()
			.. " online\b",

		objectOverrideFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(11))
			or nil,

		objectOverrideHintFont =
			(WG.Chobby
				and WG.Chobby.Configuration
				and WG.Chobby.Configuration:GetFont(11))
			or nil,

		parent = window,
	}

	SetOnlineCountVisible(
		lobby:GetConnectionStatus() == "connected"
	)

	connectivityImage = Image:New {
		name = "connectivityImage",
		x = 15,
		y = 52,
		width = 18,
		height = 18,
		keepAspect = false,
		file = IMAGE_OFFLINE,
		parent = window,
	}

	-------------------------------------------------------------------
	-- Lobby event listeners
	-------------------------------------------------------------------

	local userControl

	onAccepted = function(listener)
		userControl =
			WG.UserHandler.GetStatusUser(
				lobby:GetMyUserName(),
				USER_STATUS_WIDTH
			)

		if userControl then
			userControl:SetPos(
				USER_STATUS_X,
				USER_STATUS_Y,
				USER_STATUS_WIDTH
			)

			window:AddChild(userControl)
			window:RemoveChild(connectivityText)
		end

		WG.Delay(UpdateOnlineCount, 2)
		SetOnlineCountVisible(true)
		lobby:Ping()
	end

	onDisconnected = function(listener)
		if userControl and userControl.parent then
			window:RemoveChild(userControl)
			window:AddChild(connectivityText)
		end

		SetOnlineCountVisible(false)
		UpdateOnlineCount()
	end

	onPong = function(listener)
		--UpdateLatency()
	end

	onAddUser = function(listener, userName, status)
		if userName == lobby:GetMyUserName()
				and status.accountID then

			if WG.Chobby
					and WG.Chobby.Configuration then

				WG.Chobby.Configuration:SetConfigValue(
					"myAccountID",
					status.accountID
				)
			end
		end
	end

	onUserCount = function(listener)
		UpdateOnlineCount()
	end

	lobby:AddListener(
		"OnDisconnected",
		onDisconnected
	)

	lobby:AddListener(
		"OnAccepted",
		onAccepted
	)

	lobby:AddListener(
		"OnPong",
		onPong
	)

	lobby:AddListener(
		"OnAddUser",
		onAddUser
	)

	lobby:AddListener(
		"OnUserCount",
		onUserCount
	)
end

function UserStatusPanel.GetControl()
	local window = Control:New {
		x = 0,
		y = 0,
		right = 0,
		bottom = 0,
		padding = {
			0,
			0,
			0,
			0
		},

		OnParent = {
			function(obj)
				if obj:IsEmpty() then
					InitializeControls(obj)
				end
			end
		},
	}

	return window
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Widget Interface

local oldStatus
local onlineCountLastUpdate = 0

function widget:Update()
	local newStatus = lobby:GetConnectionStatus()

	-- On startup, synchronize the dropdown once after the lobby has actually
	-- connected. After that, the dropdown is driven only by normal user/server
	-- switch flow.
	if not startupServerSynced and newStatus == "connected" then
		SyncServerComboToCurrentServer()
		startupServerSynced = true
	end
		
	if serverSwitchPending then

		if newStatus == "connecting" then
			serverReconnectStarted = true
		end

		if newStatus == "connected" and serverReconnectStarted then
			serverSwitchPending = false
			serverReconnectStarted = false

			if serverCombo then
				serverCombo:SetEnabled(true)
			end

		-- Failed / timed out after the reconnect actually started.
		elseif serverReconnectStarted
				and (newStatus == "disconnected" or newStatus == "offline") then

			serverSwitchPending = false
			serverReconnectStarted = false

			if serverCombo then
				serverCombo:SetEnabled(true)
			end
		end
	end

	if newStatus ~= oldStatus then

		if newStatus == "disconnected"
				or newStatus == "offline" then

			btnLogout:SetCaption(
				i18n("login")
			)

			connectivityText:SetText(
				"\255\180\180\180"
				.. i18n("offline")
				.. "\b"
			)

			connectivityImage.file =
				IMAGE_OFFLINE

			connectivityImage:Invalidate()

			SetOnlineCountVisible(false)

		else

			if WG.Chobby
					and WG.Chobby.Configuration
					and WG.Chobby.Configuration.gameConfig
					and WG.Chobby.Configuration.gameConfig.logoutOpensLoginPanel then

				btnLogout:SetCaption(
					i18n("account")
				)

			else

				btnLogout:SetCaption(
					i18n("logout")
				)
			end
		end

		if newStatus == "connecting" then

			connectivityText:SetText(
				(WG.Chobby
					and WG.Chobby.Configuration
					and WG.Chobby.Configuration:GetPartialColor())
				or (
					"\255\255\255\255"
					.. i18n("connecting")
					.. "\b"
				)
			)

			connectivityImage.file =
				IMAGE_CONNECTING

			connectivityImage:Invalidate()

			SetOnlineCountVisible(false)

		elseif newStatus == "connected" then

			connectivityText:SetText(
				(WG.Chobby
					and WG.Chobby.Configuration
					and WG.Chobby.Configuration:GetSuccessColor())
				or (
					"\255\255\255\255"
					.. i18n("online")
					.. "\b"
				)
			)

			connectivityImage.file =
				IMAGE_ONLINE

			connectivityImage:Invalidate()

			SetOnlineCountVisible(true)
		end

		oldStatus = newStatus
	end

	if newStatus == "connected" then
		local now = os.clock()

		if now - onlineCountLastUpdate
				>= ONLINE_COUNT_UPDATE_INTERVAL then

			UpdateOnlineCount()
			onlineCountLastUpdate = now
		end
	end
end

function widget:GetConfigData()
    return {customServers = customServers}
end

function widget:SetConfigData(data)
    customServers = {}
    if type(data) == "table" and type(data.customServers) == "table" then
        for _, server in ipairs(data.customServers) do
            if type(server) == "table" and type(server.address) == "string" then
                local host, port = ParseServerAddress(server.address .. ":" .. tostring(server.port))
                if host then table.insert(customServers, {address = host, port = port}) end
            end
        end
    end
    RefreshServerCombo()
end

function widget:Initialize()
	VFS.Include(
		LUA_DIRNAME
			.. "widgets/chobby/headers/exports.lua",
		nil,
		VFS.RAW_FIRST
	)

	WG.UserStatusPanel =
		UserStatusPanel
end

function widget:Shutdown()
	if lobby then
		lobby:RemoveListener(
			"OnDisconnected",
			onDisconnected
		)

		lobby:RemoveListener(
			"OnAccepted",
			onAccepted
		)

		lobby:RemoveListener(
			"OnPong",
			onPong
		)

		lobby:RemoveListener(
			"OnAddUser",
			onAddUser
		)

		lobby:RemoveListener(
			"OnUserCount",
			onUserCount
		)
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------