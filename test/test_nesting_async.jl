using SentryIntegration

# SentryIntegration.init(:fake, debug=true, traces_sample_rate=1.0)
SentryIntegration.init(debug=true, traces_sample_rate=1.0)

function somefunc(t, n)
    SentryIntegration.set_task_transaction(t)
    sleep(1)
    start_transaction(op=n, description="testing sub spans") do t2
        sleep(3)
        subsomefunc()

        if n == "recurse"
            @sync @async somefunc(t2, "end recurse")
        end
    end
end

function subsomefunc()
    sleep(1)
    start_transaction(op="inside", description="double nesting") do t
        sleep(5)
    end
end



function ProperNesting()
    start_transaction(name="toplevel", op="highest") do t
        @sync begin

            @async somefunc(t, "first async")
            @async somefunc(t, "second async")
            @async somefunc(t, "recurse")
        end
    end
end

function EarlyEnd()
    t = start_transaction(op="highest")

    @sync begin

        @async somefunc(t, "first async")
        @async somefunc(t, "second async")
        @async somefunc(t, "recurse")
        finish_transaction(t)
    end

end

ProperNesting()
# EarlyEnd()
