function widget:GetInfo()
  return {name="Lobby Mods Window", author="RandomGuyJunior", date="Oct 2026",
    license="GNU GPL, v2 or later", layer=-100000, enabled=true}
end

local json = json or (VFS.Include and VFS.Include("libs/json.lua"))
local CATALOG_PATH = "LuaUI/Config/randomguy_mods_catalog.json"
local CAPABILITY = "rapid-mods-v1"
local LobbyMods = {}
local listenerBattleID, hookedLobby, originalCommandGetter
local capabilityBattleID
local requestedBattleID, requestedLobby, requestAttempts, requestTicks, respondedBattleID
local pendingCapabilities = {}
local modStates = {}
local panels = {}
local activeRequestTag
local statusQueryBattleID
local pendingMods = {}
local pendingOrder = {}
local function refreshRows()
  for _, panel in ipairs(panels) do
    if panel.entries then
      for tag, controls in pairs(panel.entries) do
        local state = modStates[tag]
        local locked = state == "Installing" or state == "Requested (await SPADS result)" or (state == "Installed" or state == "Downloaded on SPADS")
        controls.stateLabel:SetCaption(pendingMods and pendingMods[tag] and "Pending Apply" or state or "Server status unknown")
        controls.button:SetCaption(locked and (state == "Installed" and "Installed" or "Waiting") or (pendingMods and pendingMods[tag] and "Undo" or "Install"))
        controls.button:SetEnabled(not locked)
      end
    end
  end
end

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

-- Requests are staged for the Advanced Options Apply button, never sent
-- by the Mods tab itself. A server response/vote is not an installation.
function LobbyMods.DiscardPending()
  pendingMods = {}
  pendingOrder = {}
end

function LobbyMods.ApplyPending()
  if #pendingOrder == 0 then return end
  if not LobbyMods.IsAvailable() then
    Spring.Echo("[RandomGuyMods] pending mods discarded: unsupported battle")
    LobbyMods.DiscardPending()
    return
  end
  local lobby = WG.LibLobby and WG.LibLobby.lobby
  if not lobby or type(lobby.SayBattle) ~= "function" then
    Spring.Echo("[RandomGuyMods] cannot apply queued mods: battle chat unavailable")
    return
  end
  -- Do not send several simultaneous downloads: RapidMods has a single
  -- downloader and will reject concurrent !mod requests. Only one can be
  -- queued per Apply operation.
  for _, tag in ipairs(pendingOrder) do
    if pendingMods[tag] then
      local ok, err = pcall(function() lobby:SayBattle("!mod " .. tag) end)
      if ok then
        modStates[tag] = "Requested (await SPADS result)"
        activeRequestTag = tag
        refreshRows()
        Spring.Echo("[RandomGuyMods] submitted !mod " .. tag .. " on Apply")
        LobbyMods.DiscardPending()
      else
        Spring.Echo("[RandomGuyMods] !mod request failed: " .. tostring(err))
      end
      return
    end
  end
  LobbyMods.DiscardPending()
end

local function togglePending(tag, button, stateLabel, status)
  if pendingMods[tag] then
    pendingMods[tag] = nil
    pendingOrder = {}
    button:SetCaption("Install")
    stateLabel:SetCaption(modStates[tag] or "Server status unknown")
    status:SetCaption("Pending install cancelled. Click Apply to submit any remaining changes.")
  else
    -- SPADS supports one Rapid download at a time.
    for priorTag, _ in pairs(pendingMods) do
      pendingMods[priorTag] = nil
    end
    for _, panel in ipairs(panels) do
      if panel.entries then
        for otherTag, controls in pairs(panel.entries) do
          if otherTag ~= tag then
            controls.button:SetCaption("Install")
            controls.stateLabel:SetCaption(modStates[otherTag] or "Server status unknown")
          end
        end
      end
    end
    if modStates[tag] == "Installed" or modStates[tag] == "Downloaded on SPADS" or modStates[tag] == "Installing" or modStates[tag] == "Requested (await SPADS result)" then return end
    pendingMods[tag] = true
    pendingOrder = {tag}
    button:SetCaption("Undo")
    stateLabel:SetCaption("Pending Apply")
    status:SetCaption("Queued " .. tag .. ". Click Apply to request installation, or Cancel to discard.")
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
  local entryControls = {}
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
      local tag = entry.rapid_tag
      local stateLabel = Label:New {parent=item, x=12, y=58, right=135, height=20,
        caption=pendingMods[tag] and "Pending Apply" or (modStates[tag] or "Server status unknown"), align="left", font={size=12}}
      local button = Button:New {parent=item, right=10, y=15, width=110, height=35,
        caption=pendingMods[tag] and "Undo" or "Install"}
      button.OnClick = {function() togglePending(tag, button, stateLabel, status) end}
      entryControls[tag] = {button=button, stateLabel=stateLabel}
      row = row + 1
    end
  end
  status:SetCaption("Select a mod, then click Apply. SPADS enforces permissions and votes.")
  panels[#panels+1] = {control=scroll,status=status,entries=entryControls}
  refreshRows()
  return scroll
end

-- Only trust status from the current battle host, not other players.
local function onBattleChat(client, sender, message)
  local _, _, battle = currentBattle()
  if not battle or type(message) ~= "string" then return end
  local hostName = battle.founder or battle.hostName or battle.host
  if type(hostName) == "table" then hostName = hostName.userName or hostName.name end
  if not hostName or tostring(hostName) ~= tostring(sender) then return end
  local tag = message:match("^%[RapidMods%] installed ([%w_%-]+:[%w_%-]+)$")
  local state = "Installed"
  if not tag then
    tag = message:match("^%[RapidMods%] failed ([%w_%-]+:[%w_%-]+)$")
    state = "Failed"
  end
  if not tag then
    tag = message:match("^%[RapidMods%] installing ([%w_%-]+:[%w_%-]+)$")
    state = "Installing"
  end
  if not tag then return end
  modStates[tag] = state
  if activeRequestTag == tag then activeRequestTag = nil end
  Spring.Echo("[RandomGuyMods] SPADS reported " .. state .. " for " .. tag)
  refreshRows()
end

-- A private snapshot is authoritative only when sent by the battle founder.
-- Downloaded is different from activated; installation alone does not mount
-- a mod in the running game.
local function onPrivateChat(client, sender, message)
  if type(message) ~= "string" then return end
  local tags = message:match("^%[RapidModsState%] downloaded=(.*)$")
  if not tags then return end
  local _, _, battle = currentBattle()
  if not battle or tostring(sender) ~= tostring(battle.founder or "") then return end
  local downloaded = {}
  for tag in tags:gmatch("[^,]+") do
    if tag:match("^[%w_%-]+:[%w_%-]+$") then downloaded[tag] = true end
  end
  for tag, _ in pairs(modStates) do
    if modStates[tag] == "Downloaded on SPADS" then modStates[tag] = nil end
  end
  for tag, _ in pairs(downloaded) do
    if modStates[tag] ~= "Installing" and modStates[tag] ~= "Requested (await SPADS result)" then
      modStates[tag] = "Downloaded on SPADS"
    end
  end
  Spring.Echo("[RandomGuyMods] SPADS downloaded mod snapshot received")
  refreshRows()
end

local function requestModStatus()
  local lobby, battleID, battle = currentBattle()
  if not LobbyMods.IsAvailable() or statusQueryBattleID == battleID or not battle or not battle.founder then return end
  if not lobby or type(lobby.SayPrivate) ~= "function" then return end
  local ok, err = pcall(function() lobby:SayPrivate(battle.founder, "!modstatus") end)
  if ok then
    statusQueryBattleID = battleID
    Spring.Echo("[RandomGuyMods] requested SPADS downloaded mod snapshot")
  else
    Spring.Echo("[RandomGuyMods] status snapshot request failed: " .. tostring(err))
  end
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
  if tostring(currentID or "") == tostring(battleID) then respondedBattleID = battleID end
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
    if hookedLobby and originalCommandGetter and hookedLobby._GetCommandFunction == hookedLobby._rapidModsGetCommandFunction then
      hookedLobby._GetCommandFunction = originalCommandGetter
    end
    hookedLobby, originalCommandGetter = lobby, nil
    if lobby and type(lobby._GetCommandFunction) == "function" then
      -- The underlying LuaLobby dispatcher calls self:_GetCommandFunction.
      -- Hook that lookup, not lobby.commands: the dispatcher reads the
      -- lexical Interface.commands table, which need not be lobby.commands.
      originalCommandGetter = lobby._GetCommandFunction
      local wrappedGetter = function(self, cmdName)
        local handler, pattern = originalCommandGetter(self, cmdName)
        if (cmdName ~= "s.battle.extra_data" and cmdName ~= "SAIDBATTLE" and cmdName ~= "SAIDBATTLEEX" and cmdName ~= "SAIDPRIVATE") or type(handler) ~= "function" then
          return handler, pattern
        end
        return function(client, battleIDParam, data)
          handler(client, battleIDParam, data)
          if cmdName == "s.battle.extra_data" then
            onBattleExtraData(client, battleIDParam, data)
          elseif cmdName == "SAIDPRIVATE" then
            onPrivateChat(client, battleIDParam, data)
          else
            onBattleChat(client, battleIDParam, data)
          end
        end, pattern
      end
      lobby._rapidModsGetCommandFunction = wrappedGetter
      lobby._GetCommandFunction = wrappedGetter
      Spring.Echo("[RandomGuyMods] incoming command lookup hooked")
    end
  end
  if battleID ~= listenerBattleID then
    Spring.Echo("[RandomGuyMods] joined battle=" .. tostring(battleID) .. " cachedCapability=" .. tostring(battleID and pendingCapabilities[tonumber(battleID)]))
    listenerBattleID = battleID
    capabilityBattleID = (battleID and pendingCapabilities[tonumber(battleID)]) and battleID or nil
    if LobbyMods.OnCapabilityChanged then LobbyMods.OnCapabilityChanged() end
    modStates = {}
    activeRequestTag = nil
    statusQueryBattleID = nil
    LobbyMods.DiscardPending()
    panels = {}
  end
end

-- TEI only replies to accepted lobby clients. A newly joined battle can be
-- visible locally before TEI processes the join; retry briefly until any
-- authoritative extra_data response arrives. Never assume support on timeout.
local function requestBattleCapabilities()
  local lobby, battleID, battle = currentBattle()
  if not lobby or not battleID or not battle or type(lobby._SendCommand) ~= "function" then
    requestedBattleID, requestedLobby, requestAttempts, requestTicks, respondedBattleID = nil, nil, 0, 0, nil
    return
  end
  if requestedBattleID ~= battleID or requestedLobby ~= lobby then
    requestedBattleID, requestedLobby, requestAttempts, requestTicks, respondedBattleID = battleID, lobby, 0, 0, nil
  end
  if respondedBattleID == battleID or requestAttempts >= 6 then return end
  requestTicks = requestTicks + 1
  if requestAttempts > 0 and requestTicks < 4 then return end
  requestTicks = 0
  requestAttempts = requestAttempts + 1
  local ok, err = pcall(function() lobby:_SendCommand("c.battle.extra_data") end)
  if ok then
    Spring.Echo("[RandomGuyMods] requested c.battle.extra_data for battle=" .. tostring(battleID) .. " attempt=" .. tostring(requestAttempts))
  else
    Spring.Echo("[RandomGuyMods] capability request failed: " .. tostring(err))
  end
end

local frames=0
function widget:Update()
  frames=frames+1
  if frames>=15 then frames=0; syncListener(); requestBattleCapabilities(); requestModStatus() end
end

function widget:Initialize()
  VFS.Include(LUA_DIRNAME.."widgets/chobby/headers/exports.lua",nil,VFS.RAW_FIRST)
  WG.LobbyModsWindow=LobbyMods
  if WG.ModoptionsPanel and WG.ModoptionsPanel.RefreshModsCapability then
    LobbyMods.OnCapabilityChanged = WG.ModoptionsPanel.RefreshModsCapability
  end
  syncListener()
  requestBattleCapabilities()
  requestModStatus()
end
function widget:Shutdown()
  if hookedLobby and originalCommandGetter and hookedLobby._GetCommandFunction == hookedLobby._rapidModsGetCommandFunction then
    hookedLobby._GetCommandFunction = originalCommandGetter
  end
  WG.LobbyModsWindow=nil
end
