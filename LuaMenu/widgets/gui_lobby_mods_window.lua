function widget:GetInfo()
  return {name="Lobby Mods Window", author="RandomGuyJunior", date="Oct 2026",
    license="GNU GPL, v2 or later", layer=-100000, enabled=true}
end

local json = json or (VFS.Include and VFS.Include("libs/json.lua"))
local CATALOG_PATH = "LuaUI/Config/randomguy_mods_catalog.json"
local popup, status, stack
local LobbyMods = {}

local function readCatalog()
  local data = VFS.LoadFile(CATALOG_PATH)
  if not data then
    local f = io.open(CATALOG_PATH, "rb")
    if f then data = f:read("*all"); f:close() end
  end
  if not data then return nil, "Open Mod Hub once to refresh its catalog." end
  local ok, catalog = pcall(json.decode, data)
  if not ok or type(catalog) ~= "table" or tonumber(catalog.schema_version) ~= 1 or type(catalog.mods) ~= "table" then
    return nil, "Invalid Mod Hub catalog."
  end
  return catalog.mods
end

local function request(action, entry)
  if action ~= "install" then
    status:SetCaption("Server uninstall is not implemented yet; no request sent.")
    return
  end
  local tag = entry and entry.rapid_tag
  if type(tag) ~= "string" or not tag:match("^dev%-mods:[%w_%-]+$") then
    status:SetCaption("Invalid Rapid tag in the mod catalog.")
    return
  end
  -- Use the same battle-chat transport as Chobby's existing SPADS commands.
  local lobby = WG.LibLobby and WG.LibLobby.lobby
  if not lobby or not lobby.GetMyBattleID or not lobby.SayBattle
      or not lobby:GetMyBattleID() then
    status:SetCaption("Join a multiplayer battle lobby before requesting a mod.")
    return
  end
  local ok, err = pcall(function() lobby:SayBattle("!mod " .. tag) end)
  if ok then
    status:SetCaption("Sent !mod " .. tag .. " to SPADS. Watch battle chat for the result or vote.")
  else
    status:SetCaption("Could not send mod request: " .. tostring(err))
  end
end

local function refresh()
  if not stack then return end
  stack:ClearChildren()
  local mods, err = readCatalog()
  if not mods then status:SetCaption(err); return end
  local count = 0
  for _, entry in ipairs(mods) do
    if type(entry) == "table" and entry.enabled ~= false and type(entry.rapid_tag) == "string" and entry.rapid_tag:match("^dev%-mods:[%w_%-]+$") then
      count = count + 1
      local item = Panel:New {
        width="100%", height=92, padding={10,8,10,8},
        backgroundColor={0.12,0.14,0.18,0.85},
        borderColor={0.48,0.55,0.65,1},
      }
      Label:New {parent=item, x=12,y=7,right=220,height=25,
        caption=tostring(entry.name or entry.id or entry.rapid_tag),
        align="left",font={size=18}}
      Label:New {parent=item,x=12,y=36,right=220,height=40,
        caption=entry.rapid_tag,align="left",font={size=12}}
      Button:New {parent=item,right=110,y=12,width=100,height=32,
        caption="Install",OnClick={function() request("install",entry) end}}
      Button:New {parent=item,right=5,y=12,width=100,height=32,
        caption="Uninstall",OnClick={function() request("uninstall",entry) end}}
      stack:AddChild(item)
    end
  end
  stack:SetPos(nil,nil,nil,math.max(1,count*100))
  stack:Invalidate()
  status:SetCaption("Install sends !mod <tag> to SPADS via battle chat. Server controls permissions and votes.")
end

function LobbyMods.Open()
  if not popup then
    popup = Window:New {
      parent=screen0,name="lobbyModsPopup",caption="Lobby Mods",
      x="18%",y="12%",width="64%",height="76%",
      draggable=true,resizable=true,
      padding={10,36,10,10},
    }
    Button:New {parent=popup,right=10,y=5,width=100,height=27,
      caption="Close",OnClick={function() popup:Hide() end}}
    Button:New {parent=popup,right=120,y=5,width=100,height=27,
      caption="Refresh",OnClick={refresh}}
    Label:New {parent=popup,x=12,y=6,width=240,height=27,
      caption="Lobby Mods",font={size=22}}
    status=Label:New {parent=popup,x=12,y=40,right=12,height=45,
      caption="Loading server mods...",align="left",font={size=13}}
    local scroll=ScrollPanel:New {parent=popup,x=8,y=92,right=8,bottom=8,
      horizontalScrollbar=false}
    stack=StackPanel:New {parent=scroll,x=0,y=0,right=0,height=1,
      resizeItems=false,itemMargin={0,0,0,8},orientation="vertical"}
  end
  popup:Show()
  refresh()
end

function LobbyMods.Close()
  if popup then popup:Hide() end
end

function widget:Initialize()
  VFS.Include(LUA_DIRNAME.."widgets/chobby/headers/exports.lua",nil,VFS.RAW_FIRST)
  WG.LobbyModsWindow=LobbyMods
end
function widget:Shutdown()
  WG.LobbyModsWindow=nil
  if popup then popup:Dispose() end
end
