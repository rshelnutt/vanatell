--[[
VanaTell. Copyright (c) 2026 Rob Shelnutt. All rights reserved.
Proprietary software, licensed and not sold; not open source. See LICENSE
in this folder for what you may and may not do with it.
]]

-- VanaTell's own updates, from vanatell.com.
-- On load the addon asks once for addon/latest.json and, when it names a
-- newer version, says so. Nothing is downloaded or written unless the player
-- types //vt update, or the relay requires an update (it refuses this
-- version, with close code 4004, once the account has encryption on; the
-- connection then runs the same update, at most once in 10 minutes): that
-- asks again and, when the version is newer, downloads the files that differ
-- from the ones here, checks each one's size and SHA-256, backs up the files
-- it replaces into backup/, puts the new ones in place and reloads the addon.
-- //vt rollback puts the backed-up files back and reloads. Nothing is
-- written until every download has passed its check, and a failure leaves
-- the files as they were. Only files the manifest names are written, only
-- inside the addon folder, and never data/ (the settings) or backup/. The
-- network work and the hashing are pumped from prerender in bounded steps,
-- so the game never waits on them.
local update = {}

local MAX_MANIFEST = 65536         -- bytes of latest.json
local MAX_FILES = 64               -- files a manifest may name
local MAX_FILE = 4 * 1024 * 1024   -- bytes of one file
local MAX_TOTAL = 16 * 1024 * 1024 -- bytes of all of them
local MAX_DEPTH = 3                -- folders in a path, counting the file
local MANIFEST_TIMEOUT = 15        -- seconds
local FILE_TIMEOUT = 60            -- seconds per file
local TMP_SUFFIX = '.vtnew'        -- a downloaded file before it is put in place
local BACKUP = 'backup/'
local RECORD = BACKUP .. 'backup.json' -- what the last update backed up
local NOTICE = BACKUP .. 'notice.txt'  -- what the next load says: "updated X.Y.Z" or "rolled back X.Y.Z"
-- Bytes hashed per prerender, a few milliseconds' work at most: on LuaJIT
-- (Ashita), with LuaBitOp on Lua 5.1 (Windower), and with no bit library.
local BUDGET_JIT, BUDGET_BIT, BUDGET_PURE = 65536, 8192, 1024

-- SHA-256 is sha256.lua, beside this file; the names below are kept for the
-- tests that use them.
local here = debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or ''
local sha256 = dofile(here .. 'sha256.lua')
update._sha256_impl = sha256.impl
update._hasher = sha256.hasher
update._sha256 = sha256.hex

---------------------------------------------------------------------------
-- Versions, paths and the manifest.
---------------------------------------------------------------------------
-- 'X.Y.Z' -> {X, Y, Z} | nil
local function parse_version(v)
  if type(v) ~= 'string' or #v > 32 then return nil end
  local a, b, c = v:match('^(%d+)%.(%d+)%.(%d+)$')
  if not a then return nil end
  return {tonumber(a), tonumber(b), tonumber(c)}
end
update.parse_version = parse_version

-- True when version a is newer than version b.
function update.newer(a, b)
  local x, y = parse_version(a), parse_version(b)
  if not (x and y) then return false end
  for i = 1, 3 do
    if x[i] ~= y[i] then return x[i] > y[i] end
  end
  return false
end

local RESERVED = {con = true, prn = true, aux = true, nul = true}
for i = 1, 9 do RESERVED['com' .. i], RESERVED['lpt' .. i] = true, true end
local PROTECTED = {data = true, backup = true}

-- A path the manifest may name: relative, '/'-separated, letters, digits,
-- '_', '-' and '.' only, at most MAX_DEPTH parts, none of them '.' or '..'
-- or ending in a dot or a Windows device name, and not in data/ or backup/.
function update.safe_path(path)
  if type(path) ~= 'string' or #path == 0 or #path > 128 then return false end
  if path:find('[^A-Za-z0-9_%.%-/]') then return false end
  if path:lower():sub(-#TMP_SUFFIX) == TMP_SUFFIX then return false end
  local parts = {}
  for part in (path .. '/'):gmatch('([^/]*)/') do
    if part == '' or part == '.' or part == '..' or part:sub(-1) == '.' then return false end
    if RESERVED[(part:match('^[^%.]*')):lower()] then return false end
    parts[#parts + 1] = part
  end
  if #parts > MAX_DEPTH then return false end
  if PROTECTED[parts[1]:lower()] then return false end
  return true
end

-- latest.json -> {version =, files = {{path =, sha256 =, size =}, ...}} for
-- platform | nil, why
function update.parse_manifest(text, json, platform)
  if type(text) ~= 'string' then return nil, 'bad manifest' end
  local ok, m = pcall(json.decode, text)
  if not ok or type(m) ~= 'table' then return nil, 'bad manifest' end
  if not parse_version(m.version) then return nil, 'bad manifest: version' end
  local set = m[platform]
  if type(set) ~= 'table' or type(set.files) ~= 'table' then return nil, 'bad manifest: no ' .. platform .. ' files' end
  local files, seen, total, main = {}, {}, 0, false
  for _, f in ipairs(set.files) do
    if #files >= MAX_FILES then return nil, 'bad manifest: too many files' end
    if type(f) ~= 'table' or not update.safe_path(f.path) then return nil, 'bad manifest: a path is not allowed' end
    local key = f.path:lower()
    if seen[key] then return nil, 'bad manifest: ' .. f.path .. ' twice' end
    seen[key] = true
    local sha, size = f.sha256, f.size
    if type(sha) ~= 'string' or #sha ~= 64 or sha:find('[^0-9a-fA-F]') then return nil, 'bad manifest: ' .. f.path .. ' hash' end
    if type(size) ~= 'number' or size ~= size or size < 0 or size > MAX_FILE or size % 1 ~= 0 then
      return nil, 'bad manifest: ' .. f.path .. ' size'
    end
    total = total + size
    if total > MAX_TOTAL then return nil, 'bad manifest: too large' end
    if f.path == 'vanatell.lua' then main = true end
    files[#files + 1] = {path = f.path, sha256 = sha:lower(), size = size}
  end
  if not main then return nil, 'bad manifest: no vanatell.lua' end
  return {version = m.version, files = files}
end

---------------------------------------------------------------------------
-- Files.
---------------------------------------------------------------------------
local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

-- -> the file's size | nil when it cannot be opened
local function file_size(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local size = f:seek('end')
  f:close()
  return size
end

local function write_file(path, data)
  local f = io.open(path, 'wb')
  if not f then return false end
  local ok = f:write(data)
  local closed = f:close()
  return (ok and closed) and true or false
end

-- Writes data and reads it back.
local function write_checked(path, data)
  return write_file(path, data) and read_file(path) == data
end

-- Puts data at target, from tmp (already holding data) when it can be
-- renamed. Windows will not rename onto an existing file, so the old one
-- goes first; if the rename fails, data is written in place instead.
local function replace(tmp, target, data)
  os.remove(target)
  if os.rename(tmp, target) and read_file(target) == data then return true end
  os.remove(tmp)
  return write_checked(target, data)
end

---------------------------------------------------------------------------
-- The updater.
---------------------------------------------------------------------------
local U = {}
U.__index = U

-- opts: ws (http_get), json, version, platform ('windower' | 'ashita'),
-- addon_path (ending in a separator), manifest_url (false: no checks),
-- cafile, command ('//vt'), log(line) (the chat log, prefixed), chat(text)
-- (the chat log as it is), console(text), reload(), fs = {dir_exists(path),
-- create_dir(path)}, and for tests sha256 (an implementation) and budget.
function update.new(opts)
  local impl = opts.sha256 or sha256.impl()
  local budget = opts.budget
  if not budget then
    if impl.name ~= 'bit' then budget = BUDGET_PURE elseif rawget(_G, 'jit') then budget = BUDGET_JIT else budget = BUDGET_BIT end
  end
  return setmetatable({
    ws = opts.ws, json = opts.json, version = opts.version, platform = opts.platform, dir = opts.addon_path,
    url = opts.manifest_url, cafile = opts.cafile, command = opts.command or '//vt',
    log = opts.log, chat = opts.chat, console = opts.console, reload_addon = opts.reload, fs = opts.fs or {},
    impl = impl, budget = budget,
    req = nil,     -- the request in flight
    job = nil,     -- {kind = 'check' | 'update', ...} while one runs
    due = false,   -- the load check starts on the next pump
    reloading = false,
    reload_version = nil, -- the version the reload goes into, once reloading
  }, U)
end

-- Both the console and the chat log.
function U:say(text)
  pcall(self.console, text)
  self.chat(text)
end

-- One GET, with its callbacks ignored once it is no longer self.req.
function U:get(url, max_body, timeout, on_done, on_error)
  local req, err
  req, err = self.ws.http_get{
    url = url, cafile = self.cafile, max_body = max_body, timeout = timeout,
    headers = {{'User-Agent', 'VanaTell/' .. tostring(self.version) .. ' (' .. tostring(self.platform) .. ')'}},
    on_done = function(status, body)
      if req ~= self.req then return end
      self.req = nil
      on_done(status, body)
    end,
    on_error = function(e)
      if req ~= self.req then return end
      self.req = nil
      on_error(e)
    end,
  }
  if not req then return nil, err end
  self.req = req
  return true
end

function U:cancel()
  local req = self.req
  self.req = nil
  if req then req:cancel() end
end

function U:manifest(status, body)
  if status ~= 200 then return nil, 'http ' .. tostring(status) end
  return update.parse_manifest(body, self.json, self.platform)
end

-- Load: the line the last update or rollback left, then the check is due.
function U:on_load()
  local path = self.dir .. NOTICE
  local text = read_file(path)
  if text then
    os.remove(path)
    local kind, version = text:match('^(updated) (%d+%.%d+%.%d+)%s*$')
    if not kind then kind, version = text:match('^(rolled back) (%d+%.%d+%.%d+)%s*$') end
    if version and version == self.version then self:say('VanaTell: ' .. kind .. ' to ' .. version) end
  end
  self.due = self.url and true or false
end

function U:on_unload()
  self:cancel()
  self.job = nil
end

-- Every prerender: the load check once (unless a command came first), the
-- request in flight, and one bounded step of hashing.
function U:pump()
  if self.due then
    self.due = false
    if not self.job then self:check() end
  end
  if self.req then self.req:pump() end
  local job = self.job
  if job and job.step then job.step(self, job) end
end

-- The load check: says when a newer version is out. A failure goes to the
-- console only.
function U:check()
  local job = {kind = 'check'}
  self.job = job
  local function failed(why)
    if self.job == job then self.job = nil end
    pcall(self.console, 'VanaTell: update check failed: ' .. tostring(why))
  end
  local ok, err = self:get(self.url, MAX_MANIFEST, MANIFEST_TIMEOUT, function(status, body)
    local m, why = self:manifest(status, body)
    if not m then return failed(why) end
    if self.job == job then self.job = nil end
    if update.newer(m.version, self.version) then
      self:say('VanaTell ' .. m.version .. ' is available: type ' .. self.command .. ' update')
    end
  end, failed)
  if not ok then failed(err) end
end

function U:fail(job, why)
  if self.job ~= job then return end
  self.job = nil
  self:say('VanaTell: update failed: ' .. tostring(why) .. '; still on ' .. tostring(self.version))
end

-- //vt update: opts = {before_reload = fn()}, which runs once the new files
-- are in place, just before the reload. The update the connection starts
-- when the relay requires one adds auto = true and on_none = fn(): it says
-- nothing when it cannot start (an update running, reloading, updates off)
-- and skips checking for updates..., as the connection has said why it runs,
-- and on_none replaces already up to date. Its other lines are those of
-- //vt update.
function U:run_update(opts)
  opts = opts or {}
  local auto = opts.auto
  local function cannot(line) if not auto then self.log(line) end end
  if self.reloading then return cannot('reloading...') end
  if self.job and self.job.kind == 'update' then return cannot('an update is already in progress') end
  if not self.url then return cannot('updates are off in this build') end
  self:cancel()
  self.due = false -- this asks anyway
  local job = {kind = 'update', need = {}, index = 1, downloaded = {}, before_reload = opts.before_reload}
  self.job = job
  if not auto then self.log('checking for updates...') end
  local ok, err = self:get(self.url, MAX_MANIFEST, MANIFEST_TIMEOUT, function(status, body)
    local m, why = self:manifest(status, body)
    if not m then return self:fail(job, why) end
    if not update.newer(m.version, self.version) then
      self.job = nil
      if auto then
        if opts.on_none then opts.on_none() end
        return
      end
      return self.log('already up to date (' .. tostring(self.version) .. ')')
    end
    job.manifest = m
    job.step = U.scan_step
    self.log('update ' .. m.version .. ' found, applying...')
  end, function(e) self:fail(job, e) end)
  if not ok then self:fail(job, err) end
end

-- Finds the files that differ from the manifest: a missing file or one of
-- another size at once, one of the same size by its hash. One file opened
-- per step, and at most the budget hashed.
function U.scan_step(self, job)
  local files = job.manifest.files
  local f = files[job.index]
  if not f then
    job.step = nil
    job.dl = 1
    return self:download_next(job)
  end
  if not job.hasher then
    local path = self.dir .. f.path
    if file_size(path) ~= f.size then
      job.need[#job.need + 1] = f
      job.index = job.index + 1
      return
    end
    local data = read_file(path)
    if not data or #data ~= f.size then
      job.need[#job.need + 1] = f
      job.index = job.index + 1
      return
    end
    job.hasher = sha256.hasher(data, self.impl)
  end
  local digest = job.hasher:step(self.budget)
  if digest then
    if digest ~= f.sha256 then job.need[#job.need + 1] = f end
    job.hasher = nil
    job.index = job.index + 1
  end
end

function U:file_url(version, path)
  return (self.url:gsub('[^/]*$', '')) .. 'v' .. version .. '/' .. self.platform .. '/' .. path
end

-- Downloads the next file that differs, or installs once all are in.
function U:download_next(job)
  local f = job.need[job.dl]
  if not f then return self:install(job) end
  if job.dl == 1 then
    local n = #job.need
    self.log('downloading ' .. job.manifest.version .. ' (' .. n .. (n == 1 and ' file' or ' files') .. ')...')
  end
  local ok, err = self:get(self:file_url(job.manifest.version, f.path), f.size, FILE_TIMEOUT, function(status, body)
    if status ~= 200 then return self:fail(job, f.path .. ': http ' .. tostring(status)) end
    if #body ~= f.size then return self:fail(job, f.path .. ': ' .. #body .. ' bytes, expected ' .. f.size) end
    job.body, job.hasher, job.step = body, sha256.hasher(body, self.impl), U.verify_step
  end, function(e) self:fail(job, f.path .. ': ' .. tostring(e)) end)
  if not ok then self:fail(job, f.path .. ': ' .. tostring(err)) end
end

-- Hashes the file just downloaded, a budget at a time.
function U.verify_step(self, job)
  local f = job.need[job.dl]
  local digest = job.hasher:step(self.budget)
  if not digest then return end
  local body = job.body
  job.body, job.hasher, job.step = nil, nil, nil
  if digest ~= f.sha256 then return self:fail(job, f.path .. ': SHA-256 does not match') end
  job.downloaded[#job.downloaded + 1] = {path = f.path, data = body}
  job.dl = job.dl + 1
  self:download_next(job)
end

-- Creates each folder of rel (a '/'-separated path under base) that is missing.
function U:make_dirs(base, rel)
  local dir = base
  for part in rel:gmatch('([^/]+)/') do
    dir = dir .. part .. '/'
    local fs = self.fs
    if not (fs.dir_exists and fs.dir_exists(dir)) then
      if fs.create_dir then pcall(fs.create_dir, dir) end
      if not (fs.dir_exists and fs.dir_exists(dir)) then return false end
    end
  end
  return true
end

-- The backup record -> {version =, files = {paths}, added = {paths}} | nil
function U:read_record()
  local text = read_file(self.dir .. RECORD)
  if not text then return nil end
  local ok, rec = pcall(self.json.decode, text)
  if not (ok and type(rec) == 'table' and parse_version(rec.version) and type(rec.files) == 'table'
          and type(rec.added) == 'table') then
    return false
  end
  for _, list in ipairs({rec.files, rec.added}) do
    for _, path in ipairs(list) do
      if not update.safe_path(path) then return false end
    end
  end
  return rec
end

-- Copies the files about to be replaced into backup/ and writes the record.
-- The last update's backup goes first. -> old contents by path | nil, why
function U:back_up(files)
  local dir = self.dir
  if not self:make_dirs(dir, BACKUP) then return nil, 'could not create the backup folder' end
  local last = self:read_record()
  if last then
    for _, path in ipairs(last.files) do os.remove(dir .. BACKUP .. path) end
  end
  os.remove(dir .. RECORD)
  local rec, old = {version = self.version, files = {}, added = {}}, {}
  for _, d in ipairs(files) do
    local current = read_file(dir .. d.path)
    if current then
      if not (self:make_dirs(dir, BACKUP .. d.path) and write_checked(dir .. BACKUP .. d.path, current)) then
        return nil, 'could not back up ' .. d.path
      end
      rec.files[#rec.files + 1] = d.path
      old[d.path] = current
    else
      rec.added[#rec.added + 1] = d.path
    end
  end
  if not write_checked(dir .. RECORD, self.json.encode(rec)) then return nil, 'could not write the backup record' end
  return old
end

-- Puts each {path =, data =} in place: temporary copies first, all of them
-- checked, then each renamed over its file. old: the contents being replaced
-- by path (nil for a file that is new). On a failure every file already
-- replaced gets its old contents back. -> true | nil, why
function U:put_files(files, old)
  local dir, tmps = self.dir, {}
  local function discard()
    for _, tmp in ipairs(tmps) do os.remove(tmp) end
  end
  for _, d in ipairs(files) do
    if not self:make_dirs(dir, d.path) then
      discard()
      return nil, 'could not create the folder for ' .. d.path
    end
    local tmp = dir .. d.path .. TMP_SUFFIX
    tmps[#tmps + 1] = tmp
    if not write_checked(tmp, d.data) then
      discard()
      return nil, 'could not write ' .. d.path
    end
  end
  for i, d in ipairs(files) do
    if not replace(tmps[i], dir .. d.path, d.data) then
      for j = 1, i do
        local p = files[j].path
        if old[p] then write_checked(dir .. p, old[p]) elseif j < i then os.remove(dir .. p) end
      end
      discard()
      return nil, 'could not replace ' .. d.path
    end
  end
  return true
end

-- version: the one the reload goes into. before: run last, just before the
-- reload; an error in it does not stop the reload.
function U:reload(notice, version, before)
  write_file(self.dir .. NOTICE, notice .. '\n')
  self.reloading, self.reload_version = true, version
  if before then pcall(before) end
  self.reload_addon()
end

function U:install(job)
  job.step = nil
  local version = job.manifest.version
  local old, err = self:back_up(job.downloaded)
  if not old then return self:fail(job, err) end
  local ok
  ok, err = self:put_files(job.downloaded, old)
  if not ok then return self:fail(job, err) end
  self.job = nil
  self.log('installing ' .. version .. ', reloading')
  self:reload('updated ' .. version, version, job.before_reload)
end

-- //vt rollback: the files the last update replaced get their backed-up
-- contents back, the files it added go, then the backup goes and the
-- addon reloads.
function U:rollback()
  if self.reloading then return self.log('reloading...') end
  if self.job and self.job.kind == 'update' then return self.log('an update is in progress; try again once it ends') end
  local rec = self:read_record()
  if rec == nil then return self.log('nothing to roll back') end
  if not rec then return self:say('VanaTell: rollback failed: the backup record is damaged') end
  local dir, files, old = self.dir, {}, {}
  for _, path in ipairs(rec.files) do
    local data = read_file(dir .. BACKUP .. path)
    if not data then return self:say('VanaTell: rollback failed: the backup of ' .. path .. ' is missing') end
    files[#files + 1] = {path = path, data = data}
    old[path] = read_file(dir .. path)
  end
  local ok, err = self:put_files(files, old)
  if not ok then return self:say('VanaTell: rollback failed: ' .. err .. '; the files are as they were') end
  for _, path in ipairs(rec.added) do os.remove(dir .. path) end
  for _, path in ipairs(rec.files) do os.remove(dir .. BACKUP .. path) end
  os.remove(dir .. RECORD)
  self:cancel()
  self.job = nil
  self.log('restoring ' .. rec.version .. ', reloading')
  self:reload('rolled back ' .. rec.version, rec.version)
end

return update
