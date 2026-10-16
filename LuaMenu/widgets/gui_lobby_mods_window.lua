function widget:GetInfo()
  return {name="Lobby Mods Window", author="RandomGuyJunior", date="Oct 2026",
    license="GNU GPL, v2 or later", layer=-100000, enabled=true}
end

local json = json or (VFS.Include and VFS.Include("libs/json.lua"))
local CATALOG_PATH = "LuaUI/Config/randomguy_mods_catalog.json"
local CAPABILITY = "rapid-mods-v1"
local LobbyMods = {}
local listenerBattleID, hookedLobby, originalExtraDataHandler, interfaceCommands
local capabilityBattleID
local pendingCapabilities = {}
local modStates = {}
local panels = {}

local function currentBattle()
  local lobby = WG.LibLobby and WG.LibLobby.lobby
  local id = lobby and lobby.GetMyBattleID and lobby:GetMyBattleID()
  local battle = id and lobby.GetBattle and lobby:GetBattle(id)
  return lobby, id, battle
end

local function readCatalog()
  local data = VFS.LoadFile(CATALOG_PATH)
  if not data then
    local file = io.open(CATALOG_PATH, "rb")
    if file then data = file:read("*all"); file:close() end
  end
  if not data then return nil, "Open the skirmish Mod Hub once to refresh the catalog." end
  local ok, catalog = pcall(json.decode, data)
  if not ok or type(catalog) ~= "table" or tonumber(catalog.schema_version) ~= 1 or type(catalog.mods) ~= "table" then
    return nil, "Invalid Mod Hub catalog."
  end
  return catalog.mods
end

function LobbyMods.IsAvailable()
  local _, battleID, battle = currentBattle()
  return battle ~= nil and capabilityBattleID == battleID
end

local function request(entry, status)
  if not LobbyMods.IsAvailable() then
    status:SetCaption("This SPADS battle does not advertise Mod Hub support.")
    return
  end
  local tag = entry and entry.rapid_tag
  if type(tag) ~= "string" or not tag:match("^dev%-mods:[%w_%-]+$") then
    status:SetCaption("Invalid Rapid tag.")
    return
  end
  local lobby = WG.LibLobby and WG.LibLobby.lobby
  if not lobby or not lobby.SayBattle then
    status:SetCaption("Battle chat is not available.")
    return
  end
  local ok, err = pcall(function() lobby:SayBattle("!mod " .. tag) end)
  if ok then
    modStates[tag] = "Requested"
    status:SetCaption("Sent !mod " .. tag .. " to SPADS. See battle chat for the response or vote.")
  else
    status:SetCaption("Failed to send request: " .. tostring(err))
  end
end

function LobbyMods.CreateTab()
  if not LobbyMods.IsAvailable() then return nil end
  local scroll = ScrollPanel:New {
    name="randomguyModsTab", x=6, right=5, y=10, bottom=8,
    horizontalScrollbar=false,
  }
  local status = Label:New {
    parent=scroll, x=12, y=8, right=12, height=48,
    caption="Loading mods...", align="left", font={size=13},
  }
  local mods, err = readCatalog()
  if not mods then
    status:SetCaption(err)
    return scroll
  end
  local row = 0
  for _, entry in ipairs(mods) do
    if type(entry) == "table" and entry.enabled ~= false
      and type(entry.rapid_tag) == "string" and entry.rapid_tag:match("^dev%-mods:[%w_%-]+$") then
      local item = Panel:New {
        parent=scroll, x=10, y=68+row*94, right=12, height=86,
        backgroundColor={0.12,0.14,0.18,0.85},
        borderColor={0.48,0.55,0.65,1},
      }
      Label:New {parent=item, x=12, y=6, right=135, height=25,
        caption=tostring(entry.name or entry.id or entry.rapid_tag), align="left", font={size=18}}
      Label:New {parent=item, x=12, y=32, right=135, height=23,
        caption=entry.rapid_tag, align="left", font={size=12}}
      Label:New {parent=item, x=12, y=58, right=135, height=20,
        caption=modStates[entry.rapid_tag] or "Server status unknown", align="left", font={size=12}}
      Button:New {parent=item, right=10, y=15, width=110, height=35,
        caption="Install", OnClick={function() request(entry,status) end}}
      row = row + 1
    end
  end
  status:SetCaption("Install requests are sent through battle chat. SPADS enforces permissions and votes.")
  panels[#panels+1] = {control=scroll,status=status}
  return scroll
end

-- The standard Chobby Spring interface already parses s.battle.extra_data,
-- but discards it. Wrap the existing command handler without changing
-- normal lobby dispatch or sending a chat message.
local function onBattleExtraData(_, battleID, encoded)
  local _, currentID = currentBattle()
  if not tonumber(battleID) then Spring.Echo("[RandomGuyMods] extra_data invalid battleID=" .. tostring(battleID)); return end
  local ok, decoded = pcall(function()
    return json.decode(Spring.Utilities.Base64Decode(encoded))
  end)
  if not ok or type(decoded) ~= "table" then Spring.Echo("[RandomGuyMods] extra_data decode failed for battle=" .. tostring(battleID)); return end
  local enabled = false
  if type(decoded.mod_hub_capabilities) == "table" then
    for _, capability in ipairs(decoded.mod_hub_capabilities) do
      if capability == CAPABILITY then enabled = true; break end
    end
  end
  Spring.Echo("[RandomGuyMods] extra_data battle=" .. tostring(battleID) .. " current=" .. tostring(currentID) .. " supported=" .. tostring(enabled))
  pendingCapabilities[tonumber(battleID)] = enabled
  if tostring(currentID or "") ~= tostring(battleID) then return end
  local newID = enabled and currentID or nil
  if capabilityBattleID ~= newID then
    capabilityBattleID = newID
    if LobbyMods.OnCapabilityChanged then LobbyMods.OnCapabilityChanged() end
  end
end

local function syncListener()
  local lobby, battleID = currentBattle()
  if hookedLobby ~= lobby then
    if interfaceCommands and interfaceCommands["s.battle.extra_data"] == hookedLobby._rapidModsExtraDataWrapper then
      interfaceCommands["s.battle.extra_data"] = originalExtraDataHandler
    end
    hookedLobby, interfaceCommands, originalExtraDataHandler = lobby, nil, nil
    if lobby and type(lobby.commands) == "table" then
      interfaceCommands = lobby.commands
      originalExtraDataHandler = interfaceCommands["s.battle.extra_data"]
      Spring.Echo("[RandomGuyMods] lobby command handler available=" .. tostring(type(originalExtraDataHandler) == "function"))
      if type(originalExtraDataHandler) == "function" then
        local wrapper = function(self, battleIDParam, data)
          originalExtraDataHandler(self, battleIDParam, data)
          onBattleExtraData(self, battleIDParam, data)
        end
        lobby._rapidModsExtraDataWrapper = wrapper
        interfaceCommands["s.battle.extra_data"] = wrapper
      end
    else
      Spring.Echo("[RandomGuyMods] lobby.commands unavailable for capability interception")
    end
  end
  if battleID ~= listenerBattleID then
    Spring.Echo("[RandomGuyMods] joined battle=" .. tostring(battleID) .. " cachedCapability=" .. tostring(battleID and pendingCapabilities[tonumber(battleID)]))
    listenerBattleID = battleID
    capabilityBattleID = (battleID and pendingCapabilities[tonumber(battleID)]) and battleID or nil
    if LobbyMods.OnCapabilityChanged then LobbyMods.OnCapabilityChanged() end
    modStates = {}
    panels = {}
  end
end

local frames=0
function widget:Update()
  frames=frames+1
  if frames>=15 then frames=0; syncListener() end
end

function widget:Initialize()
  VFS.Include(LUA_DIRNAME.."widgets/chobby/headers/exports.lua",nil,VFS.RAW_FIRST)
  WG.LobbyModsWindow=LobbyMods
  if WG.ModoptionsPanel and WG.ModoptionsPanel.RefreshModsCapability then
    LobbyMods.OnCapabilityChanged = WG.ModoptionsPanel.RefreshModsCapability
  end
  syncListener()
end
function widget:Shutdown()
  if interfaceCommands and hookedLobby and interfaceCommands["s.battle.extra_data"] == hookedLobby._rapidModsExtraDataWrapper then
    interfaceCommands["s.battle.extra_data"] = originalExtraDataHandler
  end
  WG.LobbyModsWindow=nil
end
