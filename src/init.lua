--- Norm - public entry point. Assembled into a single `Norm` table.
--- Requires the light-class system to be loaded first (global `class`).
local NormOrm = require("orm");

---@class NormAdapters
---@field nanos NormNanosAdapterModule
---@field oxmysql NormOxMySQLAdapterModule

--- Public API surface of Norm (the value returned by the bundle / global `Norm`).
---@class Norm
---@field class LightClassFactory The (separately loaded) class system.
---@field Orm NormOrm The ORM root class.
---@field Adapter NormAdapter Base adapter class — extend (or duck-type) for custom adapters.
---@field types NormTypes Column type factories.
---@field promise NormPromiseLib Promise providers + builders.
---@field dialect NormDialects Built-in SQL dialects.
---@field adapters NormAdapters Built-in adapters.
local Norm = {};

Norm.class    = class;
Norm.Orm      = NormOrm;
Norm.Adapter  = require("adapter");
Norm.types    = require("types");
Norm.promise  = require("promise");
Norm.dialect  = require("dialect");

Norm.adapters = {
    nanos   = require("adapters.nanos"),
    oxmysql = require("adapters.oxmysql"),
};

--- Create a new ORM instance from an adapter (and optionally a promise provider).
--- This is the entry point: build it once, then `:define` your models.
--- ```lua
---     local db = Norm.new({
---         adapter = Norm.adapters.nanos.new({ engine = DatabaseEngine.SQLite, connection = "./game.db" }),
---         -- promise = Norm.promise.nanos(Promise), -- optional; auto-detected on nanos
---         log = true,
---     })
---
---     local User = db:define("users", { id = Norm.types.id(), name = Norm.types.string() })
---     db:sync():await()
--- ```
---@param options NormOptions
---@return NormOrm
function Norm.new(options)
    return NormOrm(options);
end

return Norm;
