module SentryIntegration

# Currently a dodgy wrapper around the python implementation

using PyCall
using Logging: Info, Warn, Error

export sentry_message,
    set_sentry_dsn,
    start_transaction,
    Info,
    Warn,
    Error

const override_url = Ref{String}("")
const sentry_initialised = Ref(false)

set_sentry_dsn(s) = override_url[] = s

# Technically this isn't needed.
function should_sentry()
    run_env = get(ENV, "RUN_ENV", "DEV")
    override_url[] != "" && return true
    return uppercase(run_env) ∈ ["STAGE", "PRODUCTION"]
end

macro ignore_exception(ex)
    quote
        try
            $(esc(ex))
        catch exc
            @error "Ignoring problem in sentry" exc
        end
    end
end

function maybe_init()
    if !sentry_initialised[]
        sentry_sdk = pyimport("sentry_sdk")
        @info "init sentry" dsn=override_url[]

        kwds = Dict{Symbol,Any}()
        if override_url[] != ""
            kwds[:dsn] = override_url[]
        end
        # TODO: Set this dynamically
        kwds[:traces_sample_rate] = 1.0

        sentry_sdk.init(; kwds...)
        sentry_initialised[] = true
    end
end

function sentry_message(message, level=Info)
    should_sentry() || return
    @ignore_exception begin
        maybe_init()
        @info "sending sentry message" message level
        sentry_sdk = pyimport("sentry_sdk")
        sentry_sdk.capture_message(message)
    end
    nothing
end


to_hex(x::UInt8) = lpad(string(x, base=16), 2, '0')
random_trace_id() = join(to_hex.(rand(UInt8,16)))

function start_transaction(func, args... ; kwds...)
    should_sentry() || return func()

    cm = @ignore_exception begin
        maybe_init()
        sentry_sdk = pyimport("sentry_sdk")
        cm = sentry_sdk.start_transaction(args... ; kwds...)
        cm.__enter__()
        cm
    end

    try
        return func()
    finally
        @ignore_exception cm.__exit__(nothing, nothing, nothing)
    end
end

end # module
