local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "RandomGuy Widget Migration Cleanup",
		desc = "Removes obsolete local copies of widgets now bundled by randomguy-hosting",
		author = "RandomGuyJunior",
		date = "2026-09-30",
		license = "GNU GPL, v2 or later",
		layer = 100000,
		enabled = true,
		handler = true,
	}
end

local obsoleteFiles = {
	"LuaUI/Widgets/gui_gridmenu_teamcolor.lua",
	"LuaUI/Widgets/gui_info_teamcolor.lua",
	"LuaUI/Widgets/.randomguy_updates/gui_gridmenu_teamcolor.lua.download",
	"LuaUI/Widgets/.randomguy_updates/gui_info_teamcolor.lua.download",
}

local function removeIfPresent(path)
	local f = io.open(path, "rb")
	if not f then
		return false
	end
	f:close()

	local ok, err = os.remove(path)
	if ok then
		Spring.Echo("[RandomGuy Widget Cleanup] Removed obsolete local widget copy:", path)
		return true
	end

	Spring.Echo("[RandomGuy Widget Cleanup] Could not remove", path, tostring(err))
	return false
end

function widget:Initialize()
	for i = 1, #obsoleteFiles do
		removeIfPresent(obsoleteFiles[i])
	end
end
