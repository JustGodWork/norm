--- Small helpers used across Norm. No dependencies.
---@class NormUtils
---@field logger fun(level: string, message: string)
local utils = {};

--- Default logger: prints with the Norm tag. Override via the `logger` option.
---@param level string
---@param message string
local function default_log(level, message)
    print(("[norm] [%s] %s"):format(level, message));
end

utils.logger = default_log;

--- Format and emit a log line through the active logger.
---@param level string
---@param fmt string
---@param ... any
---@return nil
function utils.log(level, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...);
    utils.logger(level, ok and msg or fmt);
end

--- Shallow copy of a table.
---@generic T: table
---@param t T
---@return T
function utils.copy(t)
    local out = {};
    for k, v in pairs(t) do out[k] = v; end
    return out;
end

--- Naive singulariser (drops a trailing "s"), for relation key/table defaults.
---@param name string
---@return string
function utils.singularize(name) return (name:gsub("s$", "")); end

--- Default pivot table name for a many-to-many: the two table singulars joined by
--- "_" in alphabetical order (e.g. `users` + `roles` -> `role_user`).
---@param a string
---@param b string
---@return string
function utils.default_pivot(a, b)
    local sa, sb = utils.singularize(a), utils.singularize(b);
    if (sa <= sb) then return sa .. "_" .. sb; end
    return sb .. "_" .. sa;
end

--- Current UTC timestamp as `YYYY-MM-DD HH:MM:SS` (portable across MySQL DATETIME
--- and SQLite TEXT). Returns nil if `os.date` is unavailable.
---@return string|nil
function utils.now_utc()
    if (type(os) ~= "table" or type(os.date) ~= "function") then return nil; end
    local ok, s = pcall(os.date, "!%Y-%m-%d %H:%M:%S");
    return ok and s or nil;
end

--- Append a "not soft-deleted" condition (`<col> IS NULL`) to a query state's
--- where list when the model uses soft deletes. No-op otherwise.
---@param state NormQueryState
---@param model NormModel
function utils.soft_scope(state, model)
    if (model.soft_deletes) then
        state.wheres = state.wheres or {};
        state.wheres[#state.wheres + 1] = { column = model.soft_deletes, op = "=", bool = "AND" };
    end
end

--- Sorted array of a dictionary's keys (stable SQL output).
---@param dict table<string, any>
---@return string[]
function utils.sorted_keys(dict)
    local keys = {};
    for k in pairs(dict) do keys[#keys + 1] = k; end
    table.sort(keys);
    return keys;
end

--- Naive fallback value escaper (adapters should prefer parameter binding).
---@param value string|number|boolean|nil
---@return string
function utils.escape(value)
    local t = type(value);
    if (value == nil) then return "NULL";
    elseif (t == "boolean") then return value and "1" or "0";
    elseif (t == "number") then return tostring(value); end
    return "'" .. tostring(value):gsub("'", "''") .. "'";
end

--- Assert with the Norm tag. Returns the (truthy) condition on success.
---@generic T
---@param condition T
---@param message string
---@return T
function utils.assert(condition, message)
    if (not condition) then
        error("[norm] " .. message, 2);
    end
    return condition;
end

return utils;
