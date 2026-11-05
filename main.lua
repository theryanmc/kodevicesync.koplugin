--[[--
KODeviceSync: keep your KOReader add-ons (plugins, user patches, fonts and
style tweaks) in a profile on a self-hosted KODeviceSync server, and pull
them onto any other device.

Push  = upload the items you selected on this device to your profile.
Pull  = download every item in your profile that is missing or different here.
Nothing is ever deleted from a device by this plugin.

@module koplugin.kodevicesync
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local socketutil = require("socketutil")
local _ = require("gettext")
local T = ffiutil.template

local SELF_NAME = "kodevicesync.koplugin"
local SKIP_NAMES = { [".git"] = true, [".DS_Store"] = true, ["__MACOSX"] = true, [".github"] = true }
local MAX_LIST_LINES = 12

local data_dir = DataStorage:getDataDir()

-- What can be synced. Each item is a top-level entry inside one of `roots`.
-- Pulled items that don't exist yet on the device are written into `dest`.
local CATEGORIES = {
    {
        id = "plugins",
        label = _("Plugins"),
        roots = { "plugins", data_dir .. "/plugins" },
        dest = data_dir .. "/plugins",
        accept = function(name, mode)
            return mode == "directory" and name:match("%.koplugin$") and name ~= SELF_NAME
        end,
    },
    {
        id = "patches",
        label = _("User patches"),
        roots = { data_dir .. "/patches" },
        dest = data_dir .. "/patches",
        accept = function(name, mode)
            return mode == "file" and (name:match("%.lua$") or name:match("%.lua%.disabled$"))
        end,
    },
    {
        id = "fonts",
        label = _("Fonts"),
        roots = { data_dir .. "/fonts" },
        dest = data_dir .. "/fonts",
        accept = function(name, mode)
            return mode == "directory" or name:lower():match("%.[ot]t[fc]$")
        end,
    },
    {
        id = "styletweaks",
        label = _("Style tweaks"),
        roots = { data_dir .. "/styletweaks" },
        dest = data_dir .. "/styletweaks",
        accept = function(name, mode)
            return mode == "directory" or name:match("%.css$")
        end,
    },
}
local CATEGORY_BY_ID = {}
for _i, cat in ipairs(CATEGORIES) do CATEGORY_BY_ID[cat.id] = cat end

-- Things that ship with KOReader. On Kobo/Kindle/PocketBook the install dir
-- and the data dir are the same folder, so user add-ons sit right next to
-- these. Used as a fallback; ota/package.index (the release's own file list)
-- is the primary source when it exists.
local FALLBACK_BUILTINS = {
    plugins = {
        "SSH", "archiveviewer", "autodim", "autofrontlight", "autostandby", "autosuspend", "autoturn",
        "autowarmth", "backgroundrunner", "batterystat", "bookshortcuts", "calibre", "cloudstorage",
        "coverbrowser", "coverimage", "docsettingtweak", "evernote", "exporter", "externalkeyboard",
        "gestures", "goodreads", "hello", "hotkeys", "httpinspector", "japanese", "keepalive",
        "kobolight", "kosync", "movetoarchive", "newsdownloader", "opds", "perceptionexpander",
        "profiles", "qrclipboard", "readtimer", "send2ebook", "statistics", "storagestat",
        "systemstat", "terminal", "texteditor", "timesync", "vocabbuilder", "wallabag", "zsync",
    },
    fonts = { "droid", "freefont", "noto", "nerdfonts" },
}

local builtin_cache
local function getBuiltins()
    if builtin_cache then return builtin_cache end
    local b = { plugins = {}, patches = {}, fonts = {}, styletweaks = {} }
    for _i, n in ipairs(FALLBACK_BUILTINS.plugins) do b.plugins[(n .. ".koplugin"):lower()] = true end
    for _i, n in ipairs(FALLBACK_BUILTINS.fonts) do b.fonts[n:lower()] = true end

    -- The release's file list, e.g. "plugins/statistics.koplugin/main.lua", "fonts/noto/NotoSans-Regular.ttf"
    local f = io.open("ota/package.index", "r")
    if f then
        for line in f:lines() do
            local rel = line:gsub("^%./", ""):gsub("^koreader/", "")
            local top, name = rel:match("^([^/]+)/([^/\r]+)")
            if top and b[top] then b[top][name:lower()] = true end
        end
        f:close()
    end

    -- Android / desktop: the install dir is separate from the data dir, so
    -- everything in the install dir's plugins folder came with KOReader.
    local install_real, data_real = ffiutil.realpath("."), ffiutil.realpath(data_dir)
    if install_real and data_real and install_real ~= data_real
            and lfs.attributes("plugins", "mode") == "directory" then
        for name in lfs.dir("plugins") do
            if name:match("%.koplugin$") then b.plugins[name:lower()] = true end
        end
    end
    builtin_cache = b
    return b
end

local function isBuiltin(cat_id, name)
    local set = getBuiltins()[cat_id]
    return set ~= nil and set[name:lower()] == true
end

-- ------------------------------------------------------------------ helpers

local function humanSize(n)
    n = n or 0
    if n < 1024 then return string.format("%d B", n) end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.1f MB", n / (1024 * 1024))
end

local function fileMd5(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return md5(data), #data
end

local function mkdirp(path)
    local cur = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. part
        if not lfs.attributes(cur, "mode") then
            lfs.mkdir(cur)
        end
        cur = cur .. "/"
    end
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or "."
end

-- Server data is untrusted: make sure every path stays inside the item.
local function isSafeItem(item)
    if type(item) ~= "table" or type(item.name) ~= "string" or type(item.files) ~= "table" then return false end
    local name = item.name
    if name == "" or name == "." or name == ".." or name == SELF_NAME
            or name:find("/", 1, true) or name:find("\\", 1, true) then
        return false
    end
    for _j, f in ipairs(item.files) do
        if type(f.path) ~= "string" or type(f.md5) ~= "string" or not f.md5:match("^%x+$") or #f.md5 ~= 32 then
            return false
        end
        if f.path:find("\\", 1, true) then return false end
        local first = true
        for part in (f.path .. "/"):gmatch("([^/]*)/") do
            if part == "" or part == "." or part == ".." then return false end
            if first and part ~= name then return false end
            first = false
        end
    end
    return true
end

local function collectFiles(item)
    local out = {}
    if item.mode == "file" then
        table.insert(out, { rel = item.name, full = item.path })
        return out
    end
    local function walk(dir, rel)
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." and not SKIP_NAMES[entry] then
                local full = dir .. "/" .. entry
                local r = rel .. "/" .. entry
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    walk(full, r)
                elseif mode == "file" then
                    table.insert(out, { rel = r, full = full })
                end
            end
        end
    end
    walk(item.path, item.name)
    table.sort(out, function(a, b) return a.rel < b.rel end)
    return out
end

local function summarize(lines)
    if #lines <= MAX_LIST_LINES then return table.concat(lines, "\n") end
    local shown = {}
    for i = 1, MAX_LIST_LINES do shown[i] = lines[i] end
    table.insert(shown, T(_("…and %1 more"), #lines - MAX_LIST_LINES))
    return table.concat(shown, "\n")
end

-- ------------------------------------------------------------------- plugin

local KODeviceSync = WidgetContainer:extend{
    name = "kodevicesync",
    is_doc_only = false,
}

function KODeviceSync:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kodevicesync.lua")
    self.ui.menu:registerToMainMenu(self)
end

function KODeviceSync:info(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

function KODeviceSync:getServer()
    local s = self.settings:readSetting("server_url") or ""
    return (s:gsub("%s+", ""):gsub("/+$", ""))
end

function KODeviceSync:isLoggedIn()
    return self:getServer() ~= "" and self.settings:readSetting("token") ~= nil
end

function KODeviceSync:deviceLabel()
    return T("KOReader (%1)", Device.model or "device")
end

-- Selection ---------------------------------------------------------------

function KODeviceSync:isSyncAll(cat_id)
    return (self.settings:readSetting("sync_all") or {})[cat_id] == true
end

function KODeviceSync:setSyncAll(cat_id, value)
    local t = self.settings:readSetting("sync_all") or {}
    t[cat_id] = value or nil
    self.settings:saveSetting("sync_all", t)
    self.settings:flush()
end

function KODeviceSync:isSelected(cat_id, name)
    if self:isSyncAll(cat_id) then return true end
    local sel = self.settings:readSetting("selected") or {}
    return sel[cat_id] ~= nil and sel[cat_id][name] == true
end

function KODeviceSync:setSelected(cat_id, name, value)
    local sel = self.settings:readSetting("selected") or {}
    sel[cat_id] = sel[cat_id] or {}
    sel[cat_id][name] = value or nil
    self.settings:saveSetting("selected", sel)
    self.settings:flush()
end

-- Built-in (shipped with KOReader) items are left out of syncing unless the
-- user explicitly opts in, so one device never overwrites another device's
-- KOReader with plugins from a different KOReader version.
function KODeviceSync:includeBuiltin()
    return self.settings:readSetting("include_builtin") == true
end

function KODeviceSync:isEligible(cat_id, name)
    return self:includeBuiltin() or not isBuiltin(cat_id, name)
end

-- Returns { [name] = { name, path, root, mode, builtin } } of what is on this device.
function KODeviceSync:scanCategory(cat)
    local items, seen = {}, {}
    for _i, root in ipairs(cat.roots) do
        local real = lfs.attributes(root, "mode") == "directory" and (ffiutil.realpath(root) or root)
        if real and not seen[real] then
            seen[real] = true
            for name in lfs.dir(root) do
                if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not items[name] then
                    local full = root .. "/" .. name
                    local mode = lfs.attributes(full, "mode")
                    if (mode == "file" or mode == "directory") and cat.accept(name, mode) then
                        items[name] = { name = name, path = full, root = root, mode = mode, builtin = isBuiltin(cat.id, name) }
                    end
                end
            end
        end
    end
    return items
end

-- HTTP --------------------------------------------------------------------

--- Make a request to the server.
-- opts.json: table to send as JSON body
-- opts.upload_file / opts.upload_size: send a file as the raw body
-- opts.download_to: write the response body into this file
-- Returns decoded JSON (or true for downloads), or nil, error_message.
function KODeviceSync:http(method, path, opts)
    opts = opts or {}
    local url = self:getServer() .. path
    local headers = { ["Accept"] = "application/json" }
    local token = self.settings:readSetting("token")
    if token and not opts.no_auth then
        headers["Authorization"] = "Bearer " .. token
    end

    local source
    if opts.json then
        local body = JSON.encode(opts.json)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    elseif opts.upload_file then
        local f = io.open(opts.upload_file, "rb")
        if not f then return nil, T(_("Cannot read %1"), opts.upload_file) end
        headers["Content-Type"] = "application/octet-stream"
        headers["Content-Length"] = tostring(opts.upload_size)
        source = ltn12.source.file(f)
    end

    local chunks, sink, out_file = {}, nil, nil
    if opts.download_to then
        out_file = io.open(opts.download_to, "wb")
        if not out_file then return nil, T(_("Cannot write %1"), opts.download_to) end
        sink = ltn12.sink.file(out_file)
    else
        sink = ltn12.sink.table(chunks)
    end

    if opts.upload_file or opts.download_to then
        socketutil:set_timeout(30, 900)
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local requester = url:match("^https://") and require("ssl.https") or require("socket.http")
    local ok, r1, code = pcall(requester.request, {
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = sink,
    })
    socketutil:reset_timeout()
    if out_file then pcall(out_file.close, out_file) end

    if not ok then
        logger.warn("kodevicesync: request failed", method, url, r1)
        return nil, T(_("Could not reach server: %1"), tostring(r1))
    end
    if r1 == nil then
        logger.warn("kodevicesync: request failed", method, url, code)
        return nil, T(_("Could not reach server: %1"), tostring(code))
    end
    local body = table.concat(chunks)
    if code ~= 200 then
        local msg = opts.download_to and "" or body
        local okj, j = pcall(JSON.decode, body)
        if okj and type(j) == "table" and j.detail then
            msg = type(j.detail) == "string" and j.detail or JSON.encode(j.detail)
        end
        if code == 401 and not opts.no_auth then
            self.settings:delSetting("token")
            self.settings:flush()
        end
        return nil, T(_("Server error %1: %2"), tostring(code), msg)
    end
    if opts.download_to then return true end
    local okj, data = pcall(JSON.decode, body)
    if not okj or type(data) ~= "table" then
        return nil, _("Unexpected response from server. Is the server address right?")
    end
    return data
end

-- Server address & login ----------------------------------------------------

function KODeviceSync:showServerDialog(on_done)
    local dlg
    dlg = InputDialog:new{
        title = _("KODeviceSync server address"),
        input = self.settings:readSetting("server_url") or "http://",
        input_hint = "http://192.168.1.10:1379",
        description = _("The address of your KODeviceSync server, including the port."),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local url = dlg:getInputText():gsub("%s+", "")
                    if url ~= "" and not url:match("^https?://") then
                        url = "http://" .. url
                    end
                    if url ~= self.settings:readSetting("server_url") then
                        self.settings:delSetting("token") -- tokens belong to one server
                    end
                    self.settings:saveSetting("server_url", url)
                    self.settings:flush()
                    UIManager:close(dlg)
                    if on_done then on_done() end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function KODeviceSync:showLogin(on_done)
    if self:getServer() == "" then
        return self:showServerDialog(function() self:showLogin(on_done) end)
    end
    local dlg
    dlg = MultiInputDialog:new{
        title = _("Log in to KODeviceSync"),
        fields = {
            { text = self.settings:readSetting("username") or "", hint = _("Username") },
            { text = "", hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Log in"),
                is_enter_default = true,
                callback = function()
                    local fields = dlg:getFields()
                    UIManager:close(dlg)
                    NetworkMgr:runWhenOnline(function()
                        self:doLogin(fields[1], fields[2])
                        if on_done then on_done() end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function KODeviceSync:doLogin(username, password)
    local res, err = self:http("POST", "/api/login", {
        no_auth = true,
        json = { username = username, password = password, device = self:deviceLabel() },
    })
    if not res then return self:info(err) end
    self.settings:saveSetting("username", res.username)
    self.settings:saveSetting("token", res.token)
    self.settings:flush()
    self:info(T(_("Logged in as %1."), res.username), 3)
end

function KODeviceSync:logout(on_done)
    UIManager:show(ConfirmBox:new{
        text = _("Log out of KODeviceSync on this device?"),
        ok_text = _("Log out"),
        ok_callback = function()
            if NetworkMgr:isOnline() then
                self:http("POST", "/api/logout") -- best effort
            end
            self.settings:delSetting("token")
            self.settings:flush()
            if on_done then on_done() end
        end,
    })
end

-- Push ----------------------------------------------------------------------

function KODeviceSync:pushItem(cat, item)
    local files, md5s, by_md5 = {}, {}, {}
    for _j, f in ipairs(collectFiles(item)) do
        local sum, size = fileMd5(f.full)
        if sum then
            table.insert(files, { path = f.rel, md5 = sum, size = size })
            if not by_md5[sum] then
                by_md5[sum] = { full = f.full, size = size }
                table.insert(md5s, sum)
            end
        end
    end
    if #files == 0 then return nil, _("no files") end

    local res, err = self:http("POST", "/api/blobs/missing", { json = { md5s = md5s } })
    if not res then return nil, err end
    for _j, sum in ipairs(res.missing or {}) do
        local b = by_md5[sum]
        if b then
            local ok, uerr = self:http("PUT", "/api/blobs/" .. sum, { upload_file = b.full, upload_size = b.size })
            if not ok then return nil, uerr end
        end
    end
    local ok, cerr = self:http("POST", "/api/items", { json = { category = cat.id, name = item.name, files = files } })
    if not ok then return nil, cerr end
    return true
end

function KODeviceSync:push()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:doPush() end)
    end)
end

function KODeviceSync:doPush()
    local todo = {}
    for _i, cat in ipairs(CATEGORIES) do
        for name, item in pairs(self:scanCategory(cat)) do
            if self:isSelected(cat.id, name) and self:isEligible(cat.id, name) then
                table.insert(todo, { cat = cat, item = item })
            end
        end
    end
    if #todo == 0 then
        return self:info(_("Nothing is selected yet.\n\nUse \"Choose what to sync\" to pick the plugins, patches, fonts and style tweaks you want in your profile."))
    end
    table.sort(todo, function(a, b)
        if a.cat.id ~= b.cat.id then return a.cat.id < b.cat.id end
        return a.item.name:lower() < b.item.name:lower()
    end)
    local lines = {}
    for _i, t in ipairs(todo) do table.insert(lines, t.cat.label .. ": " .. t.item.name) end
    if not Trapper:confirm(T(_("Upload %1 items to your profile? The server copies of these items will be replaced.\n\n%2"),
            #todo, summarize(lines)), _("Cancel"), _("Push")) then
        return
    end

    local failed = {}
    for i, t in ipairs(todo) do
        if not Trapper:info(T(_("Uploading %1 of %2\n%3"), i, #todo, t.item.name)) then
            Trapper:clear()
            return self:info(_("Push cancelled."))
        end
        local ok, err = self:pushItem(t.cat, t.item)
        if not ok then
            logger.warn("kodevicesync: push failed", t.item.name, err)
            table.insert(failed, t.item.name .. ": " .. tostring(err))
        end
    end
    Trapper:clear()
    if #failed > 0 then
        self:info(T(_("Pushed %1 of %2 items. Failed:\n\n%3"), #todo - #failed, #todo, summarize(failed)))
    else
        self:info(T(_("Pushed %1 items to your profile."), #todo), 4)
    end
end

-- Pull ----------------------------------------------------------------------

function KODeviceSync:downloadFile(f)
    mkdirp(dirname(f.dest))
    local tmp = f.dest .. ".kdsync-part"
    local ok, err = self:http("GET", "/api/blobs/" .. f.md5, { download_to = tmp })
    if not ok then
        os.remove(tmp)
        return nil, err
    end
    if fileMd5(tmp) ~= f.md5 then
        os.remove(tmp)
        return nil, _("checksum mismatch")
    end
    local renamed, rerr = os.rename(tmp, f.dest)
    if not renamed then
        os.remove(tmp)
        return nil, rerr
    end
    return true
end

function KODeviceSync:pull()
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function() self:doPull() end)
    end)
end

function KODeviceSync:doPull()
    Trapper:info(_("Fetching your profile…"))
    local manifest, err = self:http("GET", "/api/manifest")
    if not manifest then
        Trapper:clear()
        return self:info(err)
    end

    local plan, nfiles, nbytes, skipped, skipped_builtin = {}, 0, 0, 0, 0
    local local_items = {}
    for _i, item in ipairs(manifest.items or {}) do
        local cat = CATEGORY_BY_ID[item.category]
        if cat and isSafeItem(item) and not self:isEligible(cat.id, item.name) then
            skipped_builtin = skipped_builtin + 1
        elseif cat and isSafeItem(item) then
            local_items[cat.id] = local_items[cat.id] or self:scanCategory(cat)
            local existing = local_items[cat.id][item.name]
            local root = existing and existing.root or cat.dest
            local files = {}
            for _j, f in ipairs(item.files) do
                local dest = root .. "/" .. f.path
                local needed = true
                if lfs.attributes(dest, "mode") == "file" and lfs.attributes(dest, "size") == f.size then
                    needed = fileMd5(dest) ~= f.md5
                end
                if needed then
                    table.insert(files, { md5 = f.md5, size = f.size, dest = dest })
                    nbytes = nbytes + (f.size or 0)
                end
            end
            if #files > 0 then
                table.insert(plan, { cat = cat, item = item, files = files, is_new = existing == nil })
                nfiles = nfiles + #files
            else
                -- Already up to date; make sure it's in this device's selection.
                self:setSelected(cat.id, item.name, true)
            end
        else
            skipped = skipped + 1
            logger.warn("kodevicesync: skipping item", item.category, item.name)
        end
    end

    if #plan == 0 then
        Trapper:clear()
        local msg = _("This device already matches your profile.")
        if skipped_builtin > 0 then
            msg = msg .. "\n\n" .. T(_("Left %1 built-in KOReader items alone."), skipped_builtin)
        end
        return self:info(msg, 4)
    end

    local lines = {}
    for _i, p in ipairs(plan) do
        table.insert(lines, (p.is_new and _("New") or _("Update")) .. " · " .. p.cat.label .. ": " .. p.item.name)
    end
    if not Trapper:confirm(T(_("Download %1 items (%2 files, %3)?\n\n%4"),
            #plan, nfiles, humanSize(nbytes), summarize(lines)), _("Cancel"), _("Download")) then
        return
    end

    local done, failed, changed = 0, {}, 0
    for _i, p in ipairs(plan) do
        local item_ok = true
        for _j, f in ipairs(p.files) do
            done = done + 1
            if not Trapper:info(T(_("Downloading %1 of %2\n%3"), done, nfiles, p.item.name)) then
                Trapper:clear()
                return self:info(_("Pull cancelled. Run it again to finish."))
            end
            local ok, ferr = self:downloadFile(f)
            if not ok then
                item_ok = false
                table.insert(failed, p.item.name .. ": " .. tostring(ferr))
                break
            end
        end
        if item_ok then
            changed = changed + 1
            self:setSelected(p.cat.id, p.item.name, true)
        end
    end
    Trapper:clear()

    local msg
    if #failed > 0 then
        msg = T(_("Installed %1 of %2 items. Failed:\n\n%3"), changed, #plan, summarize(failed))
    else
        msg = T(_("Installed %1 items."), changed)
    end
    if skipped > 0 then
        msg = msg .. "\n\n" .. T(_("Skipped %1 items this plugin version doesn't understand."), skipped)
    end
    if skipped_builtin > 0 then
        msg = msg .. "\n\n" .. T(_("Left %1 built-in KOReader items alone."), skipped_builtin)
    end
    if changed > 0 then
        msg = msg .. "\n\n" .. _("Restart KOReader to load the new plugins, patches and fonts.")
        if UIManager.askForRestart then
            UIManager:askForRestart(msg)
            return
        end
    end
    self:info(msg)
end

-- Menu ----------------------------------------------------------------------

function KODeviceSync:addToMainMenu(menu_items)
    menu_items.kodevicesync = {
        text = _("KODeviceSync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:getMainMenu() end,
    }
end

function KODeviceSync:getMainMenu()
    local logged_in = function() return self:isLoggedIn() end
    return {
        {
            text_func = function()
                local s = self:getServer()
                return T(_("Server: %1"), s ~= "" and s or _("not set"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showServerDialog(function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        },
        {
            text_func = function()
                if self:isLoggedIn() then
                    return T(_("Log out (%1)"), self.settings:readSetting("username") or "?")
                end
                return _("Log in")
            end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                local refresh = function()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
                if self:isLoggedIn() then
                    self:logout(refresh)
                else
                    self:showLogin(refresh)
                end
            end,
        },
        {
            text = _("Choose what to sync"),
            sub_item_table_func = function() return self:getChooseMenu() end,
        },
        {
            text = _("Push this device's setup to server"),
            enabled_func = logged_in,
            callback = function() self:push() end,
        },
        {
            text = _("Pull setup from server"),
            enabled_func = logged_in,
            separator = true,
            callback = function() self:pull() end,
        },
        {
            text = _("About KODeviceSync"),
            keep_menu_open = true,
            callback = function()
                self:info(_([[KODeviceSync keeps a profile of your KOReader add-ons on your own server.

On a device that's set up the way you like: choose what to sync, then push.

On a new device: install this plugin, log in, then pull. Pull only adds and updates; it never deletes anything.

Manage your profile, or upload add-ons from a computer, in the server's web page.]]))
            end,
        },
    }
end

function KODeviceSync:getChooseMenu()
    local menu = {
        {
            text = _("Include KOReader's built-in plugins and fonts"),
            help_text = _("Off: plugins and fonts that come with KOReader are hidden here and never pushed or pulled, so each device keeps the versions from its own KOReader install."),
            checked_func = function() return self:includeBuiltin() end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                self.settings:saveSetting("include_builtin", not self:includeBuiltin() or nil)
                self.settings:flush()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
    for _i, cat in ipairs(CATEGORIES) do
        table.insert(menu, {
            text_func = function()
                if self:isSyncAll(cat.id) then
                    return T(_("%1 (all)"), cat.label)
                end
                local n = 0
                for name in pairs(self:scanCategory(cat)) do
                    if self:isSelected(cat.id, name) and self:isEligible(cat.id, name) then n = n + 1 end
                end
                return T(_("%1 (%2 selected)"), cat.label, n)
            end,
            sub_item_table_func = function() return self:getCategoryMenu(cat) end,
        })
    end
    return menu
end

function KODeviceSync:getCategoryMenu(cat)
    local items = self:scanCategory(cat)
    local names = {}
    for name in pairs(items) do
        if self:isEligible(cat.id, name) then table.insert(names, name) end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)

    local menu = {
        {
            text = _("Sync all, including ones added later"),
            checked_func = function() return self:isSyncAll(cat.id) end,
            keep_menu_open = true,
            separator = true,
            callback = function() self:setSyncAll(cat.id, not self:isSyncAll(cat.id)) end,
        },
    }
    if #names == 0 then
        table.insert(menu, {
            text = T(_("No add-ons you installed found in %1"), cat.dest),
            enabled_func = function() return false end,
        })
    end
    for _i, name in ipairs(names) do
        table.insert(menu, {
            text = items[name].builtin and T(_("%1 (built-in)"), name) or name,
            keep_menu_open = true,
            checked_func = function() return self:isSelected(cat.id, name) end,
            enabled_func = function() return not self:isSyncAll(cat.id) end,
            callback = function() self:setSelected(cat.id, name, not self:isSelected(cat.id, name)) end,
        })
    end
    return menu
end

return KODeviceSync
