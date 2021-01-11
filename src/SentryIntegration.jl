module SentryIntegration

# Currently a dodgy wrapper around the python implementation

using PyCall
using Logging: Info, Warn, Error

export sentry_message,
    Info,
    Warn,
    Error

# Technically this isn't needed.
function should_sentry()
    run_env = get(ENV, "RUN_ENV", "DEV")
    return uppercase(run_env) ∈ ["STAGE", "PRODUCTION"]
end

const sentry_initialised = Ref(false)
function sentry_message(message, level=Info)
    should_sentry() || return
    try
        sentry_sdk = pyimport("sentry_sdk")
        if !sentry_initialised[]
            sentry_sdk.init()
            sentry_initialised[] = true
        end

        sentry_sdk.capture_message(message)
    catch exc
        @error "Ignoring problem in sentry message" exc
    end
    nothing
end

end # module
