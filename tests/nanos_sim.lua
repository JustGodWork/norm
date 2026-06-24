-- Simulates a nanos-world environment to exercise the REAL nanos adapter +
-- nanos-style Promise/async/await against the built Norm bundle.
-- Globals `class` and `Norm` are already loaded by the harness.

local passed, failed = 0, 0;
local function check(name, cond, extra)
    if (cond) then passed = passed + 1; print("  [PASS] " .. name);
    else failed = failed + 1; print(("  [FAIL] %s %s"):format(name, extra and ("-> " .. tostring(extra)) or "")); end
end

-- ---- nanos-promise look-alike (Then/Catch/Await + async/await) ----
Promise = setmetatable({ __name = "Promise" }, {
    __name = "Promise",
    __call = function(self, executor)
        local p = setmetatable({ _state = "pending", _cbs = {} }, self);
        if (type(executor) == "function") then
            executor(function(v) p:_settle("ful", v); end, function(e) p:_settle("rej", e); end);
        end
        return p;
    end,
});
Promise.__index = Promise;
function Promise:_settle(state, val)
    if (self._state ~= "pending") then return; end
    self._state = state; self._value = val;
    for i = 1, #self._cbs do self._cbs[i](state, val); end
    self._cbs = {};
    if (self._thread) then coroutine.resume(self._thread); end
end
function Promise:Then(onF, onR)
    local function h(s, v) if (s == "ful") then if onF then onF(v) end else if onR then onR(v) end end end
    if (self._state == "pending") then self._cbs[#self._cbs + 1] = h; else h(self._state, self._value); end
    return self;
end
function Promise:Catch(onR) return self:Then(nil, onR); end
function Promise:Await()
    if (self._state == "pending") then self._thread = coroutine.running(); coroutine.yield(); end
    return self._value;
end
function async(fn) local co = coroutine.create(fn); coroutine.resume(co); end

-- ---- fake nanos Database / DatabaseEngine / Console ----
DatabaseEngine = { SQLite = 1, MySQL = 2, PostgreSQL = 3 };
Console = { Log = function(fmt, ...) print("  [log] " .. string.format(fmt, ...)); end };

local function make_database(engine, conn)
    local db = { engine = engine, conn = conn, calls = {}, rows = {} };
    -- Nanos passes parameters as VARARGS; capture them to assert binding.
    function db:ExecuteAsync(q, cb, ...)
        self.calls[#self.calls + 1] = { kind = "exec", q = q, params = { ... } };
        cb(1); -- affected rows
    end
    function db:SelectAsync(q, cb, ...)
        self.calls[#self.calls + 1] = { kind = "select", q = q, params = { ... } };
        if (q:find("last_insert_rowid", 1, true) or q:find("LAST_INSERT_ID", 1, true)) then
            cb({ { id = 7 } });
        else
            cb(self.rows);
        end
    end
    return db;
end
Database = setmetatable({}, { __call = function(_, engine, conn) return make_database(engine, conn); end });

-- ===============================================================
print("== Nanos adapter end-to-end (auto-detected nanos Promise) ==");

local adapter = Norm.adapters.nanos.new({ engine = DatabaseEngine.SQLite, connection = "./x.db" });
check("dialect resolved to sqlite", adapter:get_dialect_name() == "sqlite");

local db = Norm.new({ adapter = adapter });
check("provider auto-detected nanos", db.provider.name == "nanos", db.provider.name);

local User = db:define("users", {
    id    = Norm.types.id(),
    name  = Norm.types.string({ length = 64, nullable = false }),
    admin = Norm.types.boolean({ default = false }),
});

local results = {};
async(function()
    db:sync():await();
    results.synced = true;

    local user = User:create({ name = "John", admin = true }):await();
    results.created_id = user.id;            -- should be 7 (from last_insert_rowid stub)
    results.persisted = user.__persisted;

    adapter.database.rows = { { id = 7, name = "John", admin = 1 } };
    local found = User:find(7):await();
    results.found_name = found and found.name;
    results.found_admin = found and found.admin; -- boolean parse from 1
end);

check("sync completed via async/await", results.synced == true);
check("insertId via last_insert_rowid()", results.created_id == 7, results.created_id);
check("record persisted after create", results.persisted == true);
check("find returned wrapped record", results.found_name == "John", results.found_name);
check("boolean parsed from int", results.found_admin == true, tostring(results.found_admin));

-- verify the adapter actually issued the last-insert-id query
local issued_lastid = false;
for _, c in ipairs(adapter.database.calls) do
    if (c.kind == "select" and c.q:find("last_insert_rowid", 1, true)) then issued_lastid = true; end
end
check("adapter queried last_insert_rowid", issued_lastid);

-- verify INSERT parameters were bound as VARARGS (the NOT NULL bug fix)
local insert_call;
for _, c in ipairs(adapter.database.calls) do
    if (c.kind == "exec" and c.q:find("^%s*INSERT")) then insert_call = c; end
end
-- INSERT INTO `users` (`admin`, `name`) VALUES (?, ?) -> params {1, "John"}
check("insert bound 2 varargs params", insert_call and #insert_call.params == 2, insert_call and #insert_call.params);
check("insert bound admin=1, name=John",
    insert_call and insert_call.params[1] == 1 and insert_call.params[2] == "John",
    insert_call and (tostring(insert_call.params[1]) .. "," .. tostring(insert_call.params[2])));

print(("\n== RESULT: %d passed, %d failed =="):format(passed, failed));
if (failed > 0) then error("nanos sim failed"); end
