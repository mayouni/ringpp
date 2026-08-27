-- The same six algorithms as algorithms.ring, for Lua 5.4.
--
--     lua bench.lua
--
-- WHY LUA IS THE FAIR COMPARISON. Android's own ART is a JIT: it compiles
-- hot loops to native arm64, so putting it beside Ring measures "compiler
-- versus interpreter" and little else. Lua 5.4 is the same KIND of thing as
-- Ring -- a small, dynamically typed, register-based bytecode interpreter
-- with no JIT, embedded rather than hosted, in the same size class. The gap
-- to Lua is therefore a gap in interpreter engineering, which is a number
-- worth knowing; the gap to ART is a gap in compilation strategy, which is
-- a different question with a different answer.
--
-- Lua is 1-indexed, like Ring, so the loops below are near-transcriptions
-- and the arithmetic is the same arithmetic. Every CHECK value must equal
-- the Ring file's exactly.

local MOD = 1000000007

local function ms(t0) return (os.clock() - t0) * 1000 end

local function report(name, msv, check)
    print(string.format("CHECK %s %d", name, check))
    -- Formatted by hand rather than with %f so no locale can decide to put
    -- a comma where the campaign's parser expects a dot.
    local h = math.floor(msv * 100 + 0.5)
    print(string.format("TIME  %s %d.%02d", name, h // 100, h % 100))
end

local function sieve(n)
    local flag = {}
    for i = 1, n do flag[i] = 0 end
    local count = 0
    for i = 2, n do
        if flag[i] == 0 then
            count = count + 1
            local j = i * i
            while j <= n do flag[j] = 1; j = j + i end
        end
    end
    return count
end

local function matmul(n)
    local a, b = {}, {}
    for i = 1, n do
        a[i] = {}; b[i] = {}
        for j = 1, n do a[i][j] = (i + j) % 7; b[i][j] = (i * j) % 5 end
    end
    local acc = 0
    for i = 1, n do
        local row = a[i]
        for j = 1, n do
            local s = 0
            for k = 1, n do s = s + row[k] * b[k][j] end
            acc = (acc + s * (i + j)) % MOD
        end
    end
    return acc
end

local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

local function merge(a, b)
    local out, i, j = {}, 1, 1
    while i <= #a and j <= #b do
        if a[i] <= b[j] then out[#out + 1] = a[i]; i = i + 1
        else out[#out + 1] = b[j]; j = j + 1 end
    end
    while i <= #a do out[#out + 1] = a[i]; i = i + 1 end
    while j <= #b do out[#out + 1] = b[j]; j = j + 1 end
    return out
end

local function mergesort(l)
    if #l <= 1 then return l end
    local mid = #l // 2
    local left, right = {}, {}
    for i = 1, mid do left[#left + 1] = l[i] end
    for i = mid + 1, #l do right[#right + 1] = l[i] end
    return merge(mergesort(left), mergesort(right))
end

local function binsearchall(sorted, queries)
    local hits, n = 0, #sorted
    for q = 1, queries do
        local target = (q * 7919) % (n * 2)
        local lo, hi = 1, n
        while lo <= hi do
            local mid = (lo + hi) // 2
            if sorted[mid] == target then hits = hits + 1; break
            elseif sorted[mid] < target then lo = mid + 1
            else hi = mid - 1 end
        end
    end
    return hits
end

local function bytescan(s)
    local h = 0
    for i = 1, #s do h = (h * 131 + string.byte(s, i)) % MOD end
    return h
end

local function sum32(l)
    local h = 0
    for i = 1, #l do h = (h * 31 + l[i]) % MOD end
    return h
end

print("Lua 5.4 algorithm suite")
print("==============================================")
print("")

local reps = 3
local best, v, t0

best = -1
for _ = 1, reps do t0 = os.clock(); v = sieve(300000); local m = ms(t0); if best < 0 or m < best then best = m end end
report("sieve", best, v)

best = -1
for _ = 1, reps do t0 = os.clock(); v = matmul(80); local m = ms(t0); if best < 0 or m < best then best = m end end
report("matmul", best, v)

best = -1
for _ = 1, reps do t0 = os.clock(); v = fib(25); local m = ms(t0); if best < 0 or m < best then best = m end end
report("fib", best, v)

local n = 8000
local data = {}
for i = 1, n do data[i] = (i * 7919) % 100003 end
local sorted
best = -1
for _ = 1, reps do t0 = os.clock(); sorted = mergesort(data); local m = ms(t0); if best < 0 or m < best then best = m end end
for i = 2, #sorted do
    if sorted[i] < sorted[i - 1] then error("unsorted at " .. i) end
end
report("mergesort", best, sum32(sorted))

best = -1
for _ = 1, reps do t0 = os.clock(); v = binsearchall(sorted, 6000); local m = ms(t0); if best < 0 or m < best then best = m end end
report("binsearch", best, v)

local parts = {}
for _ = 1, 4000 do parts[#parts + 1] = "the quick brown fox " end
local big = table.concat(parts)
best = -1
for _ = 1, reps do t0 = os.clock(); v = bytescan(big); local m = ms(t0); if best < 0 or m < best then best = m end end
report("bytescan", best, v)

print("")
print("SUITE OK")
