
##############################
# * Transactions
#----------------------------

function start_transaction(func ; kwds...)
    t = start_transaction(; kwds...)

    try
        return func(t)
    finally
        finish_transaction(t)
    end
end

function start_transaction(; name="", trace_id=generate_uuid4(), parent_span_id=nothing, span_kwds...)
    t = get_transaction(; name, trace_id)
    if t === nothing
        return nothing
    end

    transaction, parent_span = t

    if parent_span !== nothing
        parent_span_id = parent_span.span_id
    end

    span = Span(; parent_span_id=parent_span_id, span_kwds...)
    task_local_storage(:sentry_parent_span, span)
    transaction.num_open_spans += 1

    (; transaction, parent_span, span)
end

finish_transaction(::Nothing) = nothing
function finish_transaction((transaction, parent_span, span))
    complete(span)
    push!(transaction.spans, span)
    task_local_storage(:sentry_parent_span, parent_span)
    transaction.num_open_spans -= 1
    if transaction.num_open_spans == 0
        complete(transaction)
    end
end


function get_transaction(; kwds...)
    main_hub.initialised || return nothing

    transaction = get(task_local_storage(), :sentry_transaction, nothing)
    if transaction !== nothing
        parent_span = task_local_storage(:sentry_parent_span)
        return (; transaction, parent_span)
    end

    if sample(main_hub.traces_sampler)
        transaction = Transaction(;kwds...)
        task_local_storage(:current_transaction, transaction)
    else
        transaction = nothing
    end
    return (; transaction, parent_span=nothing)
end

set_task_transaction(::Nothing) = nothing
function set_task_transaction((transaction, ignored, parent_span))
    task_local_storage(:sentry_transaction, transaction)
    task_local_storage(:sentry_parent_span, parent_span)
    nothing
end


function complete(transaction::Transaction)
    main_hub.initialised || error("Can't get here without sentry being initialised")
    capture_event(transaction)
    task_local_storage(:current_transaction, nothing)
    nothing
end

function complete(span::Span)
    if span.timestamp !== nothing
        main_hub.debug && @warn "Span attempted to be completed twice"
    else
        span.timestamp = nowstr()
    end
    nothing
end
