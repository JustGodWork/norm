--- JSON providers: the seam that lets Norm (de)serialise `json` columns with the
--- host's JSON library. A `json` field is then a Lua table in memory and a string
--- in the database, transparently. A provider is a table exposing two functions:
---   encode(value) -> string   -- Lua value  -> stored string
---   decode(text)  -> value    -- stored text -> Lua value
---
--- Built-in builders: `Norm.json.nanos|lua|raw`. The provider is auto-detected
--- per platform (Nanos `JSON`, then a Lua/FiveM `json`), or set via the `json`
--- option on `Norm.new`. Validate a custom one with `Norm.json.define`.

--- A JSON provider plugs a host's JSON library into Norm.
---@class NormJsonProvider
---@field name string
---@field encode fun(value: any): string
---@field decode fun(text: string): any

---@class NormJsonLib
local json = {};

--- Validate a custom provider (a table with `encode`/`decode`) and return it.
--- ```lua
---     local provider = Norm.json.define({
---         name = "dkjson",
---         encode = function(v) return dkjson.encode(v) end,
---         decode = function(s) return dkjson.decode(s) end,
---     })
--- ```
---@param spec NormJsonProvider
---@return NormJsonProvider
function json.define(spec)
    assert(type(spec) == "table", "[norm] json provider must be a table");
    assert(type(spec.encode) == "function", "[norm] json provider requires an 'encode' function");
    assert(type(spec.decode) == "function", "[norm] json provider requires a 'decode' function");
    return spec;
end

--- Wrap a Lua/FiveM-style library exposing `encode` / `decode` (e.g. FiveM's
--- global `json`, or a dkjson-like table). Defaults to the global `json`.
--- ```lua
---     local db = Norm.new({ adapter = a, json = Norm.json.lua() }) -- uses _ENV.json
--- ```
---@param lib? table The JSON library (defaults to `_ENV.json`).
---@return NormJsonProvider
function json.rapidjson(lib)
    lib = lib or _ENV.json;
    assert(type(lib) == "table" and type(lib.encode) == "function" and type(lib.decode) == "function",
        "[norm] json.lua requires a library with encode/decode (e.g. FiveM's `json`)");
    return {
        name = "rapidjson",
        encode = function(value) return lib.encode(value); end,
        decode = function(text) return lib.decode(text); end,
    };
end

--- Wrap the Nanos World `JSON` class (`stringify` / `parse`). Defaults to the
--- global `JSON`. On nanos this is auto-detected, so you rarely pass it.
--- ```lua
---     local db = Norm.new({ adapter = a, json = Norm.json.nanos(JSON) })
--- ```
---@param JSON? table The Nanos `JSON` class (defaults to `_ENV.JSON`).
---@return NormJsonProvider
function json.nanos(JSON)
    JSON = JSON or _ENV.JSON;
    assert(type(JSON) == "table" and type(JSON.stringify) == "function" and type(JSON.parse) == "function",
        "[norm] json.nanos requires the Nanos `JSON` class (stringify/parse)");
    return {
        name = "nanos",
        encode = function(value) return JSON.stringify(value); end,
        decode = function(text) return JSON.parse(text); end,
    };
end

--- No-op provider: `json` columns are stored and returned as raw strings (Norm's
--- behaviour before JSON providers existed). Use it to opt out of automatic
--- (de)serialisation: `Norm.new({ ..., json = false })` resolves to this.
---@return NormJsonProvider
function json.raw()
    return {
        name = "raw",
        encode = function(value) return value; end,
        decode = function(text) return text; end,
    };
end

--- Auto-detect the host's JSON library: Nanos `JSON`, then a Lua/FiveM `json`,
--- else the no-op `raw` provider. Used when no `json` option is configured and
--- the adapter offers no default.
---@return NormJsonProvider
function json.detect()
    local J = _ENV.JSON;
    if (type(J) == "table" and type(J.stringify) == "function" and type(J.parse) == "function") then
        return json.nanos(J);
    end
    local l = _ENV.json;
    if (type(l) == "table" and type(l.encode) == "function" and type(l.decode) == "function") then
        return json.rapidjson(l);
    end
    return json.raw();
end

return json;
