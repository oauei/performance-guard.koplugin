-- lib/sdr_redirect.lua
-- Centralizes document .sdr metadata from external MicroSD storage to fast internal storage

local DataStorage = require("datastorage")
local logger = require("logger")
local util = require("util")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local SdrRedirect = {
    enabled = true,
    initialized = false,
    orig_getSidecarDir = nil,
    orig_flush = nil,
}

local function isExternalStorage(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:match("^/storage/emulated/") or path:match("^/sdcard/") or path:match("^/data/") then
        return false
    end
    if path:match("^/storage/[^/]+/") or path:match("^/mnt/media_rw/") then
        return true
    end
    return false
end

local function getRedirectedSdrDir(doc_path)
    if not doc_path or doc_path == "" then return "" end
    local docsettings_dir = DataStorage:getDocSettingsDir()
    local path = doc_path:match("(.*)%.") or doc_path
    return docsettings_dir .. path .. ".sdr"
end

function SdrRedirect.isExternalStoragePath(path)
    return isExternalStorage(path)
end

function SdrRedirect.getRedirectedPath(doc_path)
    return getRedirectedSdrDir(doc_path)
end

function SdrRedirect.init(plugin_instance)
    if SdrRedirect.initialized then return end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then
        logger.err("[PerformanceGuard] Failed to require docsettings module")
        return
    end

    if not DocSettings._perf_guard_patched then
        DocSettings._perf_guard_patched = true

        SdrRedirect.orig_getSidecarDir = DocSettings.getSidecarDir
        DocSettings.getSidecarDir = function(self_ds, doc_path, force_location)
            if SdrRedirect.enabled and isExternalStorage(doc_path) then
                if force_location == nil or force_location == "dir" then
                    return getRedirectedSdrDir(doc_path)
                end
            end
            return SdrRedirect.orig_getSidecarDir(self_ds, doc_path, force_location)
        end

        SdrRedirect.orig_flush = DocSettings.flush
        DocSettings.flush = function(self_ds, data, no_custom_metadata)
            data = data or self_ds.data
            local doc_path = data and data.doc_path or (self_ds.data and self_ds.data.doc_path)

            if SdrRedirect.enabled and isExternalStorage(doc_path) then
                local target_dir = self_ds.dir_sidecar_dir or getRedirectedSdrDir(doc_path)
                util.makePath(target_dir)

                local dump = require("dump")
                local ser_data = dump(data, nil, true)
                local sidecar_file = target_dir .. "/" .. self_ds.sidecar_filename
                logger.dbg("[PerformanceGuard] Redirecting SDR write to internal flash:", sidecar_file)

                local LuaSettings = require("luasettings")
                local directory_updated = LuaSettings:backup(sidecar_file)
                util.writeToFile(ser_data, sidecar_file, true, true, directory_updated)

                if not no_custom_metadata then
                    local custom_cover = self_ds.getCustomCoverFile and self_ds:getCustomCoverFile()
                    if custom_cover and lfs.attributes(custom_cover, "mode") == "file" then
                        local _, fname = util.splitFilePathName(custom_cover)
                        local dest_cover = target_dir .. "/" .. fname
                        if custom_cover ~= dest_cover then
                            ffiutil.copyFile(custom_cover, dest_cover)
                            os.remove(custom_cover)
                            self_ds:getCustomCoverFile(true)
                        end
                    end
                end
                return
            end

            return SdrRedirect.orig_flush(self_ds, data, no_custom_metadata)
        end
    end

    SdrRedirect.initialized = true
    logger.info("[PerformanceGuard] SdrRedirect initialized successfully")
end

local function copyAndVerifyFile(src, dst)
    local rf = io.open(src, "rb")
    if not rf then return false, "Cannot open source file" end

    local dest_dir = dst:match("^(.*)/[^/]+$")
    if dest_dir then util.makePath(dest_dir .. "/") end

    local wf = io.open(dst, "wb")
    if not wf then
        rf:close()
        return false, "Cannot create destination file"
    end

    local data = rf:read("*a")
    if data then
        wf:write(data)
        wf:flush()
    end
    rf:close()
    wf:close()

    -- Verify size
    local src_size = lfs.attributes(src, "size")
    local dst_size = lfs.attributes(dst, "size")
    if src_size and dst_size and src_size == dst_size then
        return true
    end
    return false, "Verification failed: size mismatch"
end

--- Recursively finds all .sdr directories within a path
local function findSdrFolders(root_dir, results)
    results = results or {}
    if not root_dir or lfs.attributes(root_dir, "mode") ~= "directory" then
        return results
    end

    for item in lfs.dir(root_dir) do
        if item ~= "." and item ~= ".." then
            local full_path = root_dir .. "/" .. item
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                if item:sub(-4) == ".sdr" then
                    table.insert(results, full_path)
                else
                    findSdrFolders(full_path, results)
                end
            end
        end
    end
    return results
end

--- Scans external MicroSD storage and migrates all .sdr folders to internal storage
function SdrRedirect.migrateExternalSdr(progress_callback)
    local docsettings_dir = DataStorage:getDocSettingsDir()
    local sdr_folders = {}

    -- Scan external mounts under /storage/
    if lfs.attributes("/storage", "mode") == "directory" then
        for mount in lfs.dir("/storage") do
            if mount ~= "." and mount ~= ".." and mount ~= "emulated" and mount ~= "self" then
                local mount_path = "/storage/" .. mount
                if lfs.attributes(mount_path, "mode") == "directory" then
                    findSdrFolders(mount_path, sdr_folders)
                end
            end
        end
    end

    local total_folders = #sdr_folders
    local migrated_folders = 0
    local migrated_files = 0
    local failed_folders = 0

    logger.info(string.format("[PerformanceGuard] Found %d .sdr folders on external storage to migrate", total_folders))

    for idx, sdr_dir in ipairs(sdr_folders) do
        local target_sdr = docsettings_dir .. sdr_dir
        util.makePath(target_sdr .. "/")

        local folder_ok = true
        local files_in_dir = {}

        for fname in lfs.dir(sdr_dir) do
            if fname ~= "." and fname ~= ".." then
                table.insert(files_in_dir, fname)
            end
        end

        for _, fname in ipairs(files_in_dir) do
            local src_file = sdr_dir .. "/" .. fname
            local dst_file = target_sdr .. "/" .. fname

            if lfs.attributes(src_file, "mode") == "file" then
                local ok_copy, err = copyAndVerifyFile(src_file, dst_file)
                if ok_copy then
                    os.remove(src_file)
                    migrated_files = migrated_files + 1
                else
                    folder_ok = false
                    logger.err(string.format("[PerformanceGuard] Migration error copying %s to %s: %s", src_file, dst_file, tostring(err)))
                end
            end
        end

        if folder_ok then
            pcall(lfs.rmdir, sdr_dir)
            pcall(os.remove, sdr_dir)
            migrated_folders = migrated_folders + 1
        else
            failed_folders = failed_folders + 1
        end

        if progress_callback then
            progress_callback(idx, total_folders, migrated_folders)
        end
    end

    logger.info(string.format("[PerformanceGuard] Migration complete: %d folders migrated (%d files), %d failed",
        migrated_folders, migrated_files, failed_folders))

    return {
        total = total_folders,
        migrated = migrated_folders,
        files = migrated_files,
        failed = failed_folders,
    }
end

function SdrRedirect.enable()
    SdrRedirect.enabled = true
end

function SdrRedirect.disable()
    SdrRedirect.enabled = false
end

function SdrRedirect.isEnabled()
    return SdrRedirect.enabled
end

return SdrRedirect
