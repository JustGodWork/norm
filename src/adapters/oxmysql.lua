--- Adapter for oxmysql (FiveM). https://overextended.dev/oxmysql
local class = class;
local utils = require("utils");
local NormAdapter = require("adapter");
local promise = require("promise");
local jsonlib = require("json");

---@class NormOxMySQLAdapterOptions: NormAdapterOptions
---@field oxmysql? table Inject the oxmysql export (defaults to `exports.oxmysql`).

---@class NormOxMySQLAdapter: NormAdapter
---@field ox table The oxmysql export.
---@overload fun(options?: NormOxMySQLAdapterOptions): NormOxMySQLAdapter
local NormOxMySQLAdapter = class.extend("NormOxMySQLAdapter", NormAdapter);

---@param options? NormOxMySQLAdapterOptions
function NormOxMySQLAdapter:__init(options)
    options = options or {};
    NormAdapter.__init(self, options);
    self.ox = options.oxmysql or (_ENV.exports and _ENV.exports.oxmysql);
    assert(self.ox, "[norm] oxmysql export not found (is the resource a dependency?)");
    self:onReady(function()
        utils.log("DB", "oxmysql connection ready");
    end);
end

--- Wait until oxmysql has started and its connection is up, then run `cb`.
--- Runs in a background thread (Wait yields), so it never blocks construction.
---@param cb? fun(): any
function NormOxMySQLAdapter:onReady(cb)
    local ox = self.ox;
    local CreateThread = _ENV.CreateThread;
    local GetResourceState = _ENV.GetResourceState;
    local Wait = _ENV.Wait;
    local function ready()
        while (GetResourceState and GetResourceState("oxmysql") ~= "started") do
            Wait(50);
        end
        if (ox.awaitConnection) then
            ox:awaitConnection();
        end
        return cb and cb() or true;
    end
    CreateThread(ready);
end

---@return "mysql"
function NormOxMySQLAdapter:get_dialect_name()
    return "mysql";
end

--- FiveM resources have a native `promise` library; use it by default.
---@return NormPromiseProvider|nil
function NormOxMySQLAdapter:default_provider()
    if (type(_ENV.promise) == "table") then
        return promise.cfx(_ENV.promise);
    end
    return nil;
end

--- FiveM exposes a global `json` (`encode`/`decode`); use it to (de)serialise
--- `json` columns automatically.
---@return NormJsonProvider|nil
function NormOxMySQLAdapter:default_json_provider()
    if (type(_ENV.json) == "table") then
        local ok, provider = pcall(jsonlib.rapidjson, _ENV.json);
        if (ok) then return provider; end
    end
    return nil; -- fall back to auto-detection / raw passthrough
end

---@param result number|table
---@return NormExecResult
local function normalize(result)
    if (type(result) == "number") then
        return { affectedRows = result };
    elseif (type(result) == "table") then
        return { affectedRows = result.affectedRows, insertId = result.insertId };
    end
    return {};
end

---@param query string
---@param params any[]
---@param callback NormQueryCallback
function NormOxMySQLAdapter:raw_query(query, params, callback)
    -- oxmysql raises errors server-side rather than passing them to the callback.
    self.ox:query(query, params, function(rows)
        callback(nil, rows or {});
    end);
end

---@param query string
---@param params any[]
---@param callback NormExecuteCallback
function NormOxMySQLAdapter:raw_execute(query, params, callback)
    self.ox:execute(query, params, function(result)
        callback(nil, normalize(result));
    end);
end

---@class NormOxMySQLAdapterModule
---@field class NormOxMySQLAdapter
local M = {};

--- Create an oxmysql adapter instance (waits for oxmysql to be ready and logs
--- the connection). Pass it to `Norm.new`.
--- ```lua
---     local db = Norm.new({ adapter = Norm.adapters.oxmysql.new() })
---     -- defaults to the CFX `promise` provider (use :next / Citizen.Await / :await)
--- ```
---@param options? NormOxMySQLAdapterOptions
---@return NormOxMySQLAdapter
function M.new(options) return NormOxMySQLAdapter(options); end
M.class = NormOxMySQLAdapter;

return M;
