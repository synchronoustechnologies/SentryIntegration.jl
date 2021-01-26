module SentryIntegration

using AutoParameters
using Logging: Info, Warn, Error
using UUIDs
using Dates
using HTTP
using JSON
using PkgVersion
using CodecZlib

const VERSION = @PkgVersion.Version 0

export capture_message,
    capture_exception,
    start_transaction,
    Info,
    Warn,
    Error

##############################
# * Support structs
#----------------------------

@AutoParm struct Event
    event_id = generate_uuid4()
    timestamp = nowstr()
    platform = "julia"

    message = nothing
    exception = nothing
    level = nothing
end


# This is only a partial implementation - supports only one span
@AutoParm mutable struct Transaction
    event_id::String = generate_uuid4()
    span_id::String = generate_uuid4()[1:16]
    name::String
    tags = nothing
    trace_id::String = generate_uuid4()
    op = nothing
    description = nothing
    start_timestamp::String = nowstr()
    timestamp::String = ""
end

##############################
# * Hub and init
#----------------------------

struct NoSamples end
struct RatioSampler
    ratio::Float64
    function RatioSampler(x)
        @assert 0 <= x <= 1
        new(x)
    end
end

const TaskPayload = Union{Event,Transaction}
# This is to supposedly support the "unified api" of the sentry sdk. I'm not a
# fan, so it will only go partway to this goal.
# Note: a proper implementation here would make Hub a module.
@AutoParm mutable struct Hub
    initialised::Bool = false
    traces_sampler = NoSamples()

    dsn = nothing
    upstream::String = ""
    project_id::String = ""
    public_key::String = ""

    debug::Bool = false

    last_send_time = nothing
    queued_tasks = Channel{TaskPayload}(100)
    sender_task = nothing
end

const main_hub = Hub()

function init(dsn=get(ENV, "SENTRY_DSN", error("Missing DSN")) ; traces_sample_rate=nothing, traces_sampler=nothing, debug=false)
    main_hub.initialised && @warn "Sentry already initialised."
    if !main_hub.initialised
        atexit(clear_queue)
    end

    main_hub.debug = debug
    main_hub.dsn = dsn

    upstream, project_id, public_key = parse_dsn(dsn)
    main_hub.upstream = upstream
    main_hub.project_id = project_id
    main_hub.public_key = public_key
    
    @assert traces_sample_rate === nothing || traces_sampler === nothing
    if traces_sample_rate !== nothing
        main_hub.traces_sampler = RatioSampler(traces_sample_rate)
    elseif traces_sampler !== nothing
        main_hub.traces_sampler = traces_sampler
    else
        main_hub.traces_sampler = NoSamples()
    end

    main_hub.sender_task = @async send_worker()
    bind(main_hub.queued_tasks, main_hub.sender_task)
    main_hub.initialised = true

    # TODO: Return something?
    nothing
end

function parse_dsn(dsn)
    m = match(r"(?'protocol'\w+)://(?'public_key'\w+)@(?'hostname'[\w\.]+(?::\d+)?)/(?'project_id'\w+)"a, dsn)
    m === nothing && error("dsn does not fit correct format")

    upstream = "$(m[:protocol])://$(m[:hostname])"
    
    return (; upstream, project_id=m[:project_id], public_key=m[:public_key])
end

##############################
# * Utils
#----------------------------

# Need to have an extra Z at the end - this indicates UTC?
nowstr() = string(now(UTC)) * "Z"

# Useful util
macro ignore_exception(ex)
    quote
        try
            $(esc(ex))
        catch exc
            @error "Ignoring problem in sentry" exc
        end
    end
end


################################
# * Communication
#------------------------------

function generate_uuid4()
    # This is mostly just printing the UUID4 in the format we want.
    val = uuid4().value
    s = string(val, base=16)
    lpad(s, 32, '0')
end
    
# function send_event(event::Event)
#     target = "$(main_hub.upstream)/api/$(main_hub.project_id)/store/"

    
#     payload = (; event.event_id,
#                event.timestamp,
#                event.platform,
#                event.details...)
#     headers = ["Content-Type" => "application/json",
#                "content-encoding" => "gzip",
#                "User-Agent" => "SentryIntegration.jl/$VERSION",
#                "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_client=SentryIntegration.jl/$VERSION, sentry_timestamp=$(nowstr()), sentry_key=$(main_hub.public_key)"
#                ]
#     body = JSON.json(payload, 4)
#     body = Libz.deflate(Vector{UInt8}(body))
#     r = HTTP.request("POST", target, headers, body)

#     if r.status == 429
#         # TODO:
#     elseif r.status == 200
#         # TODO:
#         r.body
#     else
#         error("Unknown status $(r.status)")
#     end
# end

FilterNothings(thing) = filter(x -> x.second !== nothing, pairs(thing))

function PrepareBody(event::Event, buf)
    envelope_header = (; event.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    item = (;
            event.timestamp,
            event.platform,
            server_name = gethostname(),
            event.exception,
            event.message,
            event.level
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="event",
                   content_type="application/json",
                   length=length(item_str)+1) # +1 for the newline to come


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)
    nothing
end
function PrepareBody(transaction::Transaction, buf)
    envelope_header = (; transaction.event_id,
                       sent_at = nowstr(),
                       dsn = main_hub.dsn
                       )

    trace = (; 
            transaction.trace_id,
            transaction.op,
            transaction.description,
            transaction.tags,
            transaction.span_id,
             parent_span_id = nothing,
            ) |> FilterNothings

    item = (; type="transaction",
            platform = "julia",
            server_name = gethostname(),
            transaction.event_id,
            transaction = transaction.name,
            transaction.start_timestamp,
            transaction.timestamp,
            transaction.tags,
            contexts = (; trace),
            spans = [],
            ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="transaction",
                   content_type="application/json",
                   length=length(item_str)+1) # +1 for the newline to come


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)
    nothing
end

# The envelope version
function send_envelope(task::TaskPayload)
    target = "$(main_hub.upstream)/api/$(main_hub.project_id)/envelope/"

    headers = ["Content-Type" => "application/x-sentry-envelope",
               "content-encoding" => "gzip",
               "User-Agent" => "SentryIntegration.jl/$VERSION",
               "X-Sentry-Auth" => "Sentry sentry_version=7, sentry_client=SentryIntegration.jl/$VERSION, sentry_timestamp=$(nowstr()), sentry_key=$(main_hub.public_key)"
               ]

    buf = PipeBuffer()
    stream = CodecZlib.GzipCompressorStream(buf)
    PrepareBody(task, buf)
    body = read(stream)
    close(stream)

    if main_hub.debug
        @info "Sending HTTP request" typeof(task)
    end
    r = HTTP.request("POST", target, headers, body)
    if r.status == 429
        # TODO:
    elseif r.status == 200
        # TODO:
        r.body
    else
        error("Unknown status $(r.status)")
    end
end

function send_worker()
    while true
        try
            event = take!(main_hub.queued_tasks)
            send_envelope(event)
        catch exc
            if main_hub.debug
                @error "Sentry error"
                showerror(stderr, exc, catch_backtrace())
            end
        end
    end
end

function clear_queue()
    while !isempty(main_hub.queued_tasks)
        @info "Tidying up some sentry tasks before closing"
        send_envelope(event)
        yield()
    end
end


####################################
# * Basic capturing
#----------------------------------



function capture_event(task::TaskPayload)
    main_hub.initialised || return

    push!(main_hub.queued_tasks, task)
end

function capture_message(message, level=Info)
    main_hub.initialised || return

    capture_event(Event(message=(; formatted=message),
                        level=lowercase(string(level))))
end

# This assumes that we are calling from within a catch
capture_exception(exc::Exception) = capture_exception([(exc, catch_backtrace())])
function capture_exception(exceptions=catch_stack())
    main_hub.initialised || return

    formatted_excs = map(exceptions) do (exc,strace)
        bt = Base.scrub_repl_backtrace(strace)
        # frames = map(Base.stacktrace(strace, false)) do frame
        frames = map(bt) do frame
            Dict(:filename => frame.file,
             :function => frame.func,
             :lineno => frame.line)
        end
             
        Dict(:type => typeof(exc).name.name,
         :module => string(typeof(exc).name.module),
         :value => hasproperty(exc, :msg) ? exc.msg : sprint(showerror, exc),
         :stacktrace => (;frames=frames))
    end
    capture_event(Event(exception=(;values=formatted_excs),
                        level="error"))
end


##############################
# * Transactions
#----------------------------

function start_transaction(func ; kwds...)
    transaction = get_transaction(; kwds...)
    try
        return func()
    finally
        complete(transaction)
    end
end

function get_transaction(; kwds...)
    main_hub.initialised || return nothing
    transaction = Transaction(;kwds...)
end

complete(::Nothing) = nothing
function complete(transaction::Transaction)
    main_hub.initialised || error("Can't get here without sentry being initialised")
    transaction.timestamp = nowstr()
    capture_event(transaction)
end

end # module
