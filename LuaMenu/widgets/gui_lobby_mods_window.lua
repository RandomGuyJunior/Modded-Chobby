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
  if not ok or type(catalog) ~= "table" or type(catalog.mods) ~= "table" then
    return nil, "Invalid Mod Hub catalog."
  end
  return catalog.mods
end

local function request(action, entry)
  -- Transport, permissions, vote handling and installation are server-authoritative.
  -- Never infer moderator/host/alone status from launcher state.
  if not (WG.LobbyModRequests and WG.LobbyModRequests.Request) then
    status:SetCaption("Server mod requests are not available on this lobby yet.")
    return
  end
  local ok, result = pcall(WG.LobbyModRequests.Request, action, entry.rapid_tag)
  status:SetCaption(ok and (result or "Request sent; awaiting server response.") or
    ("Request failed: " .. tostring(result)))
end

local function refresh()
  if not stack then return end
  stack:ClearChildren()
  local mods, err = readCatalog()
  if not mods then status:SetCaption(err); return end
  local count = 0
  for _, entry in ipairs(mods) do
    if entry.enabled ~= false and type(entry.rapid_tag) == "string" then
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
  status:SetCaption("Server decides: moderator, boss or sole player = direct request; others = vote.")
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
