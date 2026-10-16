# Ring's error model, measured. Four findings, rising in seriousness.
#
#     ring error_model.ring
#
# 1. cCatchError is a STRING; the error's identity is inside the text,
#    so branching on error kind means parsing a human-facing message.
# 2. raise() accepts only a string -- raise([:code = 42]) fails with an
#    error ABOUT PARAMETER TYPES, replacing the intent rather than
#    flattening it.
# 3. There is no `finally`, which is where §11.6's ring_state_delete
#    most needs to run.
# 4. cCatchError is a PROCESS-GLOBAL that a callee overwrites. An error
#    handler cannot rely on the error it is handling.
#
# Lua, which is smaller than Ring, returns any value from pcall intact:
#     error({code=42}) -> pcall gives the TABLE back.
# Python catches by type and runs finally on the error path.

func Main
    ? "=== 1. the error is text, and its identity is inside the text"
    try
        x = 10 / 0
    catch
        ? "  type = " + type(cCatchError) + "   value = [" + cCatchError + "]"
    done

    ? ""
    ? "=== 2. raise() cannot carry structure"
    try
        raise([ :code = 42, :detail = "structured" ])
    catch
        ? "  raise(list) -> [" + cCatchError + "]"
        ? "  (an error about PARAMETER TYPES: the intent is replaced, not flattened)"
    done

    ? ""
    ? "=== 3. no finally -- try / catch / done only"

    ? ""
    ? "=== 4. cCatchError is a global a callee overwrites"
    try
        raise("first")
    catch
        ? "  handler A caught      : [" + cCatchError + "]"
        Helper()
        ? "  handler A after Helper: [" + cCatchError + "]   <-- A's error is gone"
    done

    ? ""
    ? "=== and there is no stack"
    try
        aCalls = ringvm_callslist()
    catch
        ? "  ringvm_callslist() -> " + cCatchError
    done

func Helper
    try
        raise("second, from Helper")
    catch
        # a handler's FIRST act is normally to log -- and logging is a call
    done
