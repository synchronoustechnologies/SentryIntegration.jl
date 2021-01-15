module SentryIntegration

# Currently a dodgy wrapper around the python implementation

using PyCall
using Logging: Info, Warn, Error

export sentry_message,
    set_sentry_dsn,
    Info,
    Warn,
    Error

const override_url = Ref{String}("")

set_sentry_dsn(s) = override_url[] = s

# Technically this isn't needed.
function should_sentry()
    run_env = get(ENV, "RUN_ENV", "DEV")
    return uppercase(run_env) ∈ ["STAGE", "PRODUCTION"]
end

function maybe_init()
    if !sentry_initialised[]
        sentry_sdk = pyimport("sentry_sdk")
        @info "init sentry" dsn=override_url[]
        if override_url[] == ""
            sentry_sdk.init()
        else
            sentry_sdk.init(dsn=override_url[])
        end
        sentry_initialised[] = true
    end
end

const sentry_initialised = Ref(false)
function sentry_message(message, level=Info)
    should_sentry() || return
    try
        maybe_init()
        
        @info "sending sentry message" message level
        sentry_sdk = pyimport("sentry_sdk")
        sentry_sdk.capture_message(message)
    catch exc
        @error "Ignoring problem in sentry message" exc
    end
    nothing
end

end # module
