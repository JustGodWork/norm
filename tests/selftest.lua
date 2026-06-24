-- Norm self-test. Run against the built bundle: light-class.lua + dist/norm.lua
-- must already be loaded (global `class` and global `Norm`).
local orm = Norm;
local class = orm.class;

local passed, failed = 0, 0;
local function check(name, cond, extra)
    if (cond) then
        passed = passed + 1;
        print(("  [PASS] %s"):format(name));
    else
        failed = failed + 1;
        print(("  [FAIL] %s %s"):format(name, extra and ("-> " .. tostring(extra)) or ""));
    end
end

-- Mock adapter: records SQL, returns canned results.
local Mock = class.extend("MockAdapter", orm.Adapter);
function Mock:__init(opts)
    orm.Adapter.__init(self, opts);
    self.calls = {};
    self.next_id = 0;
    self.query_result = {};
end
function Mock:raw_query(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "query", sql = q, params = p };
    cb(nil, self.query_result);
end
function Mock:raw_execute(q, p, cb)
    self.calls[#self.calls + 1] = { kind = "execute", sql = q, params = p };
    if (q:match("^%s*[Ii][Nn][Ss][Ee][Rr][Tt]")) then
        self.next_id = self.next_id + 1;
        cb(nil, { affectedRows = 1, insertId = self.next_id });
    else
        cb(nil, { affectedRows = 1 });
    end
end
local function last_sql(mock) return mock.calls[#mock.calls].sql; end

print("== Test group 1: builtin provider (mysql dialect) ==");
local mock = Mock({ dialect = "mysql" });
local db = orm.new({ adapter = mock, promise = orm.promise.builtin() });

local User = db:define("users", {
    id    = orm.types.id(),
    name  = orm.types.string({ length = 64, nullable = false }),
    email = orm.types.string({ length = 128, unique = true }),
    admin = orm.types.boolean({ default = false }),
    age   = orm.types.integer({ default = 0 }),
});

db:sync();
local create = last_sql(mock);
print("  CREATE: " .. create);
check("create table name", create:find("CREATE TABLE IF NOT EXISTS `users`", 1, true) ~= nil);
check("id is PK auto_increment", create:find("`id` INT PRIMARY KEY AUTO_INCREMENT", 1, true) ~= nil);
check("name VARCHAR(64) NOT NULL", create:find("`name` VARCHAR(64) NOT NULL", 1, true) ~= nil);
check("email UNIQUE", create:find("`email` VARCHAR(128) UNIQUE", 1, true) ~= nil);
check("engine suffix", create:find("ENGINE=InnoDB", 1, true) ~= nil);

local created;
User:create({ name = "John", email = "john@x.io", admin = true }):next(function(u) created = u; end);
print("  INSERT: " .. last_sql(mock));
check("insert omits autoincrement id", last_sql(mock):find("`id`", 1, true) == nil);
check("insert resolved record", created ~= nil);
check("insert assigned insertId", created and created.id == 1, created and created.id);
check("record persisted", created and created.__persisted == true);
check("boolean stored as 1", (function()
    for _, v in ipairs(mock.calls[#mock.calls].params) do if (v == 1) then return true; end end
    return false;
end)());

mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
local found;
User:find(1):next(function(u) found = u; end);
print("  SELECT find: " .. last_sql(mock));
check("find select where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("find select limit 1", last_sql(mock):find("LIMIT 1", 1, true) ~= nil);
check("found record name", found and found.name == "John");
check("boolean parsed to true", found and found.admin == true, found and tostring(found.admin));

mock.query_result = {};
User:where("age", ">", 18):order("name", "DESC"):limit(10):offset(5):all();
local sel = last_sql(mock);
print("  SELECT query: " .. sel);
check("where op >", sel:find("WHERE `age` > ?", 1, true) ~= nil);
check("order by desc", sel:find("ORDER BY `name` DESC", 1, true) ~= nil);
check("limit/offset", sel:find("LIMIT 10 OFFSET 5", 1, true) ~= nil);

mock.query_result = {};
User:query():where({ name = "John" }):where_in("id", { 1, 2, 3 }):all();
local sel2 = last_sql(mock);
print("  SELECT in: " .. sel2);
check("where_in placeholders", sel2:find("`id` IN (?, ?, ?)", 1, true) ~= nil);

found.age = 42;
local saved;
found:save():next(function(u) saved = u; end);
print("  UPDATE: " .. last_sql(mock));
check("update statement", last_sql(mock):find("UPDATE `users` SET", 1, true) ~= nil);
check("update where pk", last_sql(mock):find("WHERE `id` = ?", 1, true) ~= nil);
check("update never sets pk", (function()
    local setpart = last_sql(mock):match("SET (.-) WHERE");
    return setpart ~= nil and setpart:find("`id`", 1, true) == nil;
end)());
check("save resolved record", saved == found);

found:delete();
print("  DELETE: " .. last_sql(mock));
check("delete statement", last_sql(mock):find("DELETE FROM `users` WHERE `id` = ?", 1, true) ~= nil);

mock.query_result = { { count = 7 } };
local n;
User:count():next(function(c) n = c; end);
check("count value", n == 7, n);

print("== Test group 2: sqlite dialect DDL ==");
local mock2 = Mock({ dialect = "sqlite" });
local db2 = orm.new({ adapter = mock2, promise = orm.promise.builtin() });
local Item = db2:define("items", {
    id   = orm.types.id(),
    name = orm.types.string({ length = 32 }),
});
db2:sync();
local createS = last_sql(mock2);
print("  CREATE (sqlite): " .. createS);
check("sqlite integer pk autoincrement", createS:find("`id` INTEGER PRIMARY KEY AUTOINCREMENT", 1, true) ~= nil);
check("sqlite string -> TEXT", createS:find("`name` TEXT", 1, true) ~= nil);
check("sqlite no engine suffix", createS:find("ENGINE", 1, true) == nil);

print("== Test group 3: portability (nanos-style provider with :Then, no :next) ==");
local FakeP = {};
FakeP.__index = FakeP;
local function fake_new(executor)
    local self = setmetatable({ state = "pending", cbs = {} }, FakeP);
    executor(function(v)
        self.value = v; self.state = "ful";
        for i = 1, #self.cbs do self.cbs[i](v); end
    end, function(e) self.err = e; self.state = "rej"; end);
    return self;
end
function FakeP:Then(f)
    if (self.state == "ful") then f(self.value); else self.cbs[#self.cbs + 1] = f; end
    return self;
end
local fakeProvider = {
    name = "fake-nanos",
    new = fake_new,
    resolve = function(v) return fake_new(function(r) r(v); end); end,
    reject = function(e) return fake_new(function(_, j) j(e); end); end,
};

local mock3 = Mock({ dialect = "mysql" });
local db3 = orm.new({ adapter = mock3, promise = fakeProvider });
local Post = db3:define("posts", { id = orm.types.id(), title = orm.types.string({ length = 80 }) });

local ok_sync = false;
db3:sync():Then(function() ok_sync = true; end);
check("sync works with :Then-only provider", ok_sync);

local post;
Post:create({ title = "Hello" }):Then(function(p) post = p; end);
check("create works with :Then-only provider", post ~= nil and post.id == 1, post and post.id);

mock3.query_result = { { id = 1, title = "Hello" } };
local got;
Post:find(1):Then(function(p) got = p; end);
check("find works with :Then-only provider", got ~= nil and got.title == "Hello");

print("== Test group 4: builtin promise chaining (:next / :catch) ==");
local p1ok, caught;
orm.promise.builtin().resolve(10)
    :next(function(v) return v + 5; end)
    :next(function(v) p1ok = (v == 15); end);
check("builtin :next chains transforms", p1ok);

orm.promise.builtin().new(function(_, reject) reject("boom"); end)
    :catch(function(e) caught = e; end);
check("builtin :catch catches", caught == "boom");

print("== Test group 5: duck-typed adapter (no class system) ==");
local plain = {
    _calls = {},
    get_dialect = function(self) return orm.dialect.mysql; end,
    default_provider = function(self) return nil; end,
    raw_query = function(self, q, p, cb) cb(nil, {}); end,
    raw_execute = function(self, q, p, cb) self._calls[#self._calls + 1] = q; cb(nil, { affectedRows = 1, insertId = 9 }); end,
};
local db5 = orm.new({ adapter = plain, promise = orm.promise.builtin() });
local Plain = db5:define("plain", { id = orm.types.id(), v = orm.types.integer() });
local pid;
Plain:create({ v = 1 }):next(function(r) pid = r.id; end);
check("duck-typed adapter works", pid == 9, pid);

print("== Test group 6: builtin promise :await() ==");
-- already-resolved: returns immediately inside a coroutine
coroutine.wrap(function()
    local v = orm.promise.builtin().resolve(42):await();
    check("await on resolved promise", v == 42, v);
end)();

-- pending then settled: await yields, settle resumes the coroutine
local deferred;
local p_pending = orm.promise.builtin().new(function(resolve) deferred = resolve; end);
local awaited;
local co = coroutine.create(function() awaited = p_pending:await(); end);
coroutine.resume(co);          -- blocks at :await()
check("await suspends while pending", awaited == nil);
deferred(99);                  -- settles -> resumes the coroutine
check("await resumes with value", awaited == 99, awaited);

-- rejection: :await() raises
coroutine.wrap(function()
    local ok, err = pcall(function() return orm.promise.builtin().reject("nope"):await(); end);
    check("await raises on rejection", (not ok) and tostring(err):find("nope", 1, true) ~= nil);
end)();

-- end-to-end: await an ORM operation through the builtin provider
coroutine.wrap(function()
    mock.query_result = { { id = 1, name = "John", email = "john@x.io", admin = 1, age = 0 } };
    local u = User:find(1):await();
    check("await an ORM query result", u and u.name == "John", u and u.name);
end)();

print("== Test group 7: custom promise class (auto-wrapped via from_class) ==");
-- A framework promise with a `Class(executor)` constructor and its OWN :await()
-- (like no-more-rp's). Passing the CLASS directly should auto-wrap it.
local Custom = {};
Custom.__index = Custom;
setmetatable(Custom, { __call = function(cls, executor)
    local p = setmetatable({ state = "pending" }, cls);
    if (type(executor) == "function") then
        executor(
            function(v) if (p.state == "pending") then p.state, p.value = "fulfilled", v; if p.co then coroutine.resume(p.co) end end end,
            function(e) if (p.state == "pending") then p.state, p.value = "rejected", e; if p.co then coroutine.resume(p.co) end end end
        );
    end
    return p;
end });
function Custom:await()
    if (self.state == "pending") then self.co = coroutine.running(); coroutine.yield(); end
    if (self.state == "rejected") then error(self.value); end
    return self.value;
end

local mock7 = Mock({ dialect = "mysql" });
local db7 = orm.new({ adapter = mock7, promise = Custom }); -- pass the CLASS, not a provider
check("auto-wrapped class -> provider name 'class'", db7.provider.name == "class", db7.provider.name);
local U7 = db7:define("u7", { id = orm.types.id(), name = orm.types.string({ length = 32 }) });
coroutine.wrap(function()
    local r = U7:create({ name = "Z" }):await();   -- uses the class's own :await()
    check("await on auto-wrapped custom promise", r and r.name == "Z", r and r.name);
end)();

print(("\n== RESULT: %d passed, %d failed =="):format(passed, failed));
if (failed > 0) then error("self-test failed"); end
