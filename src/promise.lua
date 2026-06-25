--- Promise providers: the seam that makes Norm portable across frameworks.
---
--- The ORM core never builds a promise directly; it asks the configured
--- *provider*. A provider is a table exposing three functions:
---   new(executor)  -> promise   -- executor(resolve, reject)
---   resolve(value) -> promise
---   reject(reason) -> promise
---
--- Because the ORM resolves each promise with the already-transformed value,
--- providers need NOT support chaining. That lets us plug in even tiny promise
--- libraries (such as the nanos one).
local class = class; -- light-class global (loaded before this bundle)
local utils = require("utils");

--- A promise provider plugs a framework's promise type into Norm.
--- Built-in builders: `Norm.promise.builtin|nanos|cfx`. Validate a custom one
--- with `Norm.promise.define`.
---@class NormPromiseProvider
---@field name string
---@field new fun(executor: fun(resolve: fun(value: any), reject: fun(reason: any))): any Returns a framework promise.
---@field resolve fun(value: any): any Already-resolved promise.
---@field reject fun(reason: any): any Already-rejected promise.
---@field is_promise? fun(value: any): boolean

---@class NormPromiseLib
local promise = {};

-- =====================================================================
-- Built-in zero-dependency promise (used by promise.builtin()).
-- =====================================================================

---@class NormPromise: LightClass
---@field private _state "pending"|"fulfilled"|"rejected"
---@field private _value any
---@field private _queue fun(state: string, value: any)[]
---@field private _await_co thread?
---@overload fun(executor?: fun(resolve: fun(value: any), reject: fun(reason: any))): NormPromise
local NormPromise = class.new("NormPromise");

---@param executor? fun(resolve: fun(value: any), reject: fun(reason: any))
function NormPromise:__init(executor)
    self._state = "pending";
    self._value = nil;
    self._queue = {};
    if (type(executor) == "function") then
        local ok, err = pcall(executor,
            function(v) self:_settle("fulfilled", v); end,
            function(e) self:_settle("rejected", e); end
        );
        if (not ok) then self:_settle("rejected", err); end
    end
end

function NormPromise:_settle(state, value)
    if (self._state ~= "pending") then return; end
    self._state = state;
    self._value = value;
    local queue = self._queue;
    self._queue = {};
    for i = 1, #queue do queue[i](state, value); end
    -- Wake up a coroutine blocked in :await().
    if (self._await_co) then
        local co = self._await_co;
        self._await_co = nil;
        local ok, err = coroutine.resume(co);
        if (not ok) then
            -- The awaited continuation raised AFTER being resumed here. resume()
            -- captured the error and there's no caller to propagate it to, so
            -- surface it — otherwise it vanishes and the coroutine looks like it
            -- silently hung. A traceback of the (dead) coroutine pinpoints the line.
            local tb = (type(debug) == "table" and debug.traceback)
                and debug.traceback(co, tostring(err)) or tostring(err);
            utils.logger("ERROR", "uncaught error after await: " .. tb);
        end
    end
end

--- Register handlers; returns a new chained promise.
---@param on_fulfilled? fun(value: any): any
---@param on_rejected? fun(reason: any): any
---@return NormPromise
function NormPromise:next(on_fulfilled, on_rejected)
    return NormPromise(function(resolve, reject)
        local function handle(state, value)
            local handler = (state == "fulfilled") and on_fulfilled or on_rejected;
            if (type(handler) ~= "function") then
                if (state == "fulfilled") then resolve(value); else reject(value); end
                return;
            end
            local ok, result = pcall(handler, value);
            if (not ok) then
                reject(result);
            elseif (type(result) == "table" and type(result.next) == "function") then
                result:next(resolve, reject);
            else
                resolve(result);
            end
        end
        if (self._state == "pending") then
            self._queue[#self._queue + 1] = handle;
        else
            handle(self._state, self._value);
        end
    end);
end

---@param on_rejected fun(reason: any): any
---@return NormPromise
function NormPromise:catch(on_rejected)
    return self:next(nil, on_rejected);
end

--- Block the current coroutine until the promise settles, then return its value
--- (or raise its rejection reason). Must be called from inside a coroutine.
---@return any value
function NormPromise:await()
    if (self._state == "pending") then
        local co, is_main = coroutine.running();
        assert(not is_main, "[norm] NormPromise:await() must be called from a coroutine");
        self._await_co = co;
        coroutine.yield();
    end
    if (self._state == "rejected") then
        error(self._value);
    end
    return self._value;
end

promise.NormPromise = NormPromise;

-- =====================================================================
-- Typed promise overlays (annotations only).
--
-- At runtime every ORM operation returns the configured provider's promise.
-- These subtypes change nothing at runtime; they only narrow `:await()` (and
-- `:next()`) so the editor knows the resolved value's type. Example:
--   NormModel:create(...)         -> NormRecordPromise
--   NormModel:create(...):await() -> NormRecord
-- =====================================================================

---@class NormRecordPromise: NormPromise
---@field await fun(self: NormRecordPromise): NormRecord
---@field next fun(self: NormRecordPromise, on_fulfilled?: fun(value: NormRecord): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormRecordListPromise: NormPromise
---@field await fun(self: NormRecordListPromise): NormRecord[]
---@field next fun(self: NormRecordListPromise, on_fulfilled?: fun(value: NormRecord[]): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormRecordOrNilPromise: NormPromise
---@field await fun(self: NormRecordOrNilPromise): NormRecord?
---@field next fun(self: NormRecordOrNilPromise, on_fulfilled?: fun(value: NormRecord?): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormNumberPromise: NormPromise
---@field await fun(self: NormNumberPromise): number
---@field next fun(self: NormNumberPromise, on_fulfilled?: fun(value: number): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormBooleanPromise: NormPromise
---@field await fun(self: NormBooleanPromise): boolean
---@field next fun(self: NormBooleanPromise, on_fulfilled?: fun(value: boolean): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormRowsPromise: NormPromise
---@field await fun(self: NormRowsPromise): table[]
---@field next fun(self: NormRowsPromise, on_fulfilled?: fun(value: table[]): any, on_rejected?: fun(reason: any): any): NormPromise

---@class NormExecResultPromise: NormPromise
---@field await fun(self: NormExecResultPromise): NormExecResult
---@field next fun(self: NormExecResultPromise, on_fulfilled?: fun(value: NormExecResult): any, on_rejected?: fun(reason: any): any): NormPromise

--- Attach an `await` method to a framework-native promise (so `promise:await()`
--- works uniformly across providers). No-op if the promise already exposes one
--- (checked through inheritance, so a lib's own `:await()` is never clobbered).
---@generic T
---@param p T
---@param awaiter fun(self: T): any
---@return T
local function attach_await(p, awaiter)
    if (type(p) == "table" and p.await == nil) then
        rawset(p, "await", awaiter);
    end
    return p;
end

-- =====================================================================
-- Provider validation + built-in providers
-- =====================================================================

--- Validate a custom provider (a table with `new`/`resolve`/`reject`) and return
--- it. Use this to plug any promise system that isn't builtin/nanos/cfx.
--- ```lua
---     local provider = Norm.promise.define({
---         name    = "myfw",
---         new     = function(executor) ... end,
---         resolve = function(value) ... end,
---         reject  = function(reason) ... end,
---     })
--- ```
---@param spec NormPromiseProvider
---@return NormPromiseProvider
function promise.define(spec)
    assert(type(spec) == "table", "[norm] promise provider must be a table");
    assert(type(spec.new) == "function", "[norm] promise provider requires a 'new' function");
    assert(type(spec.resolve) == "function", "[norm] promise provider requires a 'resolve' function");
    assert(type(spec.reject) == "function", "[norm] promise provider requires a 'reject' function");
    return spec;
end

--- Build a provider from any promise CLASS whose constructor is
--- `Class(executor)` (executor receives resolve, reject) — e.g. a custom or
--- framework promise. The class is expected to provide its own await/chaining
--- methods (no `:await()` alias is attached). Use this when your framework's
--- promise differs from nanos-promise / CFX.
--- ```lua
---     local db = Norm.new({ adapter = a, promise = Norm.promise.from_class(Promise) })
--- ```
---@param PromiseClass fun(executor: fun(resolve: fun(value: any), reject: fun(reason: any))): any
---@return NormPromiseProvider
function promise.from_class(PromiseClass)
    assert(PromiseClass ~= nil, "[norm] promise.from_class requires a promise class");
    return {
        name = "class",
        new = function(executor) return PromiseClass(executor); end,
        resolve = function(value) return PromiseClass(function(res) res(value); end); end,
        reject = function(reason) return PromiseClass(function(_, rej) rej(reason); end); end,
    };
end

--- The bundled zero-dependency provider (real then-able with :next/:catch/:await).
--- The default when no provider is configured and the adapter has none.
--- ```lua
---     local db = Norm.new({ adapter = a, promise = Norm.promise.builtin() })
--- ```
---@return NormPromiseProvider
function promise.builtin()
    return {
        name = "builtin",
        new = function(executor) return NormPromise(executor); end,
        resolve = function(value) return NormPromise(function(res) res(value); end); end,
        reject = function(reason) return NormPromise(function(_, rej) rej(reason); end); end,
        is_promise = function(v) return class.is_instance_of(v, NormPromise); end,
    };
end

--- Wrap the nanos-promise `Promise` class so the ORM returns nanos promises.
--- On nanos this is auto-detected, so you rarely pass it explicitly.
--- ```lua
---     local db = Norm.new({ adapter = a, promise = Norm.promise.nanos(Promise) })
--- ```
---@param Promise table The nanos `Promise` class.
---@return NormPromiseProvider
function promise.nanos(Promise)
    assert(Promise, "[norm] promise.nanos requires the nanos Promise class");
    -- nanos promises expose :Await(); add a lowercase :await() alias for uniformity.
    local awaiter = function(self) return self:Await(); end;
    return {
        name = "nanos",
        new = function(executor) return attach_await(Promise(executor), awaiter); end,
        resolve = function(value) return attach_await(Promise(function(res) res(value); end), awaiter); end,
        reject = function(reason) return attach_await(Promise(function(_, rej) rej(reason); end), awaiter); end,
        is_promise = function(v)
            local mt = type(v) == "table" and getmetatable(v);
            return mt ~= nil and mt.__name == "Promise";
        end,
    };
end

--- Wrap FiveM's native `promise` library. The oxmysql adapter uses this by
--- default, so you rarely pass it explicitly.
--- ```lua
---     local db = Norm.new({ adapter = a, promise = Norm.promise.cfx() })
--- ```
---@param lib? table The CFX `promise` library (defaults to the global `promise`).
---@return NormPromiseProvider
function promise.cfx(lib)
    lib = lib or _ENV.promise;
    assert(type(lib) == "table" and type(lib.new) == "function",
        "[norm] promise.cfx requires FiveM's `promise` library");
    -- CFX promises are awaited via Citizen.Await; expose it as :await() too.
    local awaiter = function(self)
        local Citizen = _ENV.Citizen;
        assert(Citizen and Citizen.Await, "[norm] Citizen.Await is unavailable");
        return Citizen.Await(self);
    end;
    return {
        name = "cfx",
        new = function(executor)
            local p = lib.new();
            local ok, err = pcall(executor,
                function(v) p:resolve(v); end,
                function(e) p:reject(e); end);
            if (not ok) then p:reject(err); end
            return attach_await(p, awaiter);
        end,
        resolve = function(value) local p = lib.new(); p:resolve(value); return attach_await(p, awaiter); end,
        reject = function(reason) local p = lib.new(); p:reject(reason); return attach_await(p, awaiter); end,
        is_promise = function(v) return type(v) == "table" and type(v.next) == "function"; end,
    };
end

return promise;
