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
