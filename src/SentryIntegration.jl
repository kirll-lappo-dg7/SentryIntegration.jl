module SentryIntegration

using AutoParameters
using Logging: Info, Warn, Error, LogLevel
using UUIDs
using Dates
using HTTP
using JSON
using PkgVersion
using CodecZlib

const VERSION = PkgVersion.@Version 0

export capture_message,
    capture_exception,
    start_transaction,
    finish_transaction,
    set_task_transaction,
    set_tag,
    Info,
    Warn,
    Error

module SentryLogger

include("./SentryLogging.jl")

export apply_sentry_logger

end


include("structs.jl")
include("transactions.jl")

##############################
# * Init
#----------------------------


const main_hub = Hub()
const global_tags = Dict{String,String}()

function init(dsn=nothing; release=nothing, traces_sample_rate=nothing, traces_sampler=nothing, debug=false, dry_mode=nothing)
    main_hub.initialised && @warn "Sentry Sdk must be initialized once."

    set_dry_mode(main_hub, dry_mode)
    set_dsn(main_hub, dsn)
    set_release(main_hub, release)
    set_environment()

    if !main_hub.dry_mode && is_nothing_or_empty(main_hub.dsn)
        @warn "[Sentry]: Sentry Dsn is not specified, no event will be sent"
        return
    end

    if main_hub.dry_mode
        @warn "[Sentry]: Dry Mode is enabled, the SDK will be initialized but no event will be sent to Sentry."
    end

    if !main_hub.initialised
        atexit(clear_queue)
    end

    main_hub.debug = debug

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
    if isnothing(dsn)
        return (; is_valid=false, upstream="", project_id="", public_key="")
    end

    m = match(r"(?'protocol'\w+)://(?'public_key'\w+)@(?'hostname'[\w\.]+(?::\d+)?)/(?'project_id'\w+)"a, dsn)
    if dsn === "" || isnothing(m)
        @warn "[Sentry]: Sentry Dsn does not fit correct format, sdk will not be enabled" dsn = dsn
        return (; is_valid=false, upstream="", project_id="", public_key="")
    end

    upstream = "$(m[:protocol])://$(m[:hostname])"

    return (; is_valid=true, upstream=upstream, project_id=m[:project_id], public_key=m[:public_key])
end

function get_sentry_dsn()
    get_env_var("SENTRY_DSN")
end

function get_sentry_release()
    get_env_var("SENTRY_RELEASE")
end

function get_sentry_environment()
    get_env_var("SENTRY_ENVIRONMENT")
end

function get_sentry_dry_mode()
    get_env_var("SENTRY_JULIASDK_DRY_MODE")
end

function get_env_var(name, default=nothing)
    get(ENV, name, default)
end

function set_release(hub::Hub, release)
    if isnothing(release)
        release = get_sentry_release()
    end

    if isnothing(release)
        @warn "[Sentry]: Sentry Release is not specified"
    end

    hub.release = release
end

function set_environment()
    environment = get_sentry_environment()
    if !isnothing(environment)
        set_tag("environment", environment)
    end
end

function set_dsn(hub::Hub, dsn)
    if isnothing(dsn)
        dsn = get_sentry_dsn()
    end

    is_valid, upstream, project_id, public_key = parse_dsn(dsn)

    if (is_valid)
        hub.dsn = dsn
        hub.upstream = upstream
        hub.project_id = project_id
        hub.public_key = public_key
    end
end

function set_dry_mode(hub::Hub, dry_mode)
    if isnothing(dry_mode)
        dry_mode = !is_nothing_or_empty(get_sentry_dry_mode())
    end

    hub.dry_mode = dry_mode
end

function is_nothing_or_empty(value)
    isnothing(value) || value === ""
end

####################################################
# * Globally applied things
#--------------------------------------------------


function set_tag(name::String, value::String)
    if name === "release"
        @warn "[Sentry]: A 'release' tag is ignored by Sentry upstream. You should instead set the release in the `init` call or via SENTRY_RELEASE variable"
    end

    global_tags[name] = value
end

##############################
# * Utils
#----------------------------

# Need to have an extra Z at the end - this indicates UTC
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

FilterNothings(thing) = filter(x -> x.second !== nothing, pairs(thing))
function MergeTags(args...)
    args = filter(!=(nothing), args)
    isempty(args) && return nothing
    out = merge(pairs.(args)...)
    isempty(out) && return nothing
    out
end

function PrepareBody(event::Event, buf)
    envelope_header = (; event.event_id,
        sent_at=nowstr(),
        dsn=main_hub.dsn
    )

    item = (;
        event.timestamp,
        event.platform,
        server_name=gethostname(),
        event.exception,
        event.message,
        event.level,
        main_hub.release,
        tags=MergeTags(global_tags, event.tags),
    ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="event",
        content_type="application/json",
        length=sizeof(item_str))


    println(buf, JSON.json(envelope_header))
    println(buf, JSON.json(item_header))
    println(buf, item_str)

    for attachment in event.attachments
        attachment_str = JSON.json((; data=attachment))
        attachment_header = (; type="attachment",
            length=sizeof(attachment_str),
            content_type="application/json")

        println(buf, JSON.json(attachment_header))
        println(buf, attachment_str)
    end


    nothing
end
function PrepareBody(transaction::Transaction, buf)
    envelope_header = (; transaction.event_id,
        sent_at=nowstr(),
        dsn=main_hub.dsn
    )

    if main_hub.debug && any(span -> span.timestamp === nothing, transaction.spans)
        @warn "At least one span didn't complete before the transaction completed"
    end

    spans = map(transaction.spans) do span
        (;
            transaction.trace_id,
            span.parent_span_id,
            span.span_id,
            span.tags,
            span.op,
            span.description,
            span.start_timestamp,
            span.timestamp)
    end
    #root_span = popfirst!(spans)
    # root_span = pop!(spans)
    root_span = transaction.root_span

    trace = (;
        transaction.trace_id,
        root_span.op,
        root_span.description,
        root_span.tags,
        root_span.span_id,
        root_span.parent_span_id,
    ) |> FilterNothings

    item = (; type="transaction",
        platform="julia",
        server_name=gethostname(),
        transaction.event_id,
        transaction=transaction.name,
        # root_span...,
        root_span.start_timestamp,
        root_span.timestamp,
        tags=MergeTags(global_tags, root_span.tags), contexts=(; trace),
        spans=FilterNothings.(spans),
    ) |> FilterNothings
    item_str = JSON.json(item)

    item_header = (; type="transaction",
        content_type="application/json",
        length=sizeof(item_str) + 1) # +1 for the newline to come


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
    body = nothing
    try
        PrepareBody(task, buf)
        body = read(stream)
    catch ex
        @debug "[Sentry]: Error at preparing task body" exception = (ex)
    finally
        close(stream)
    end


    if main_hub.debug
        body_text = String(transcode(CodecZlib.GzipDecompressor, body))
        @debug "[Sentry]: Sending HTTP request" task = typeof(task) body_text = body_text
    end

    if main_hub.dry_mode
        return
    end

    r = HTTP.request("POST", target, headers, body)

    if main_hub.debug
        @debug "[Sentry]: Sentry response" response = r
    end

    if r.status == 429
        # TODO:
    elseif r.status == 200
        # TODO:
        r.body
    else
        @debug "[Sentry]: [ERROR]: Sentry server returned unknown status $(r.status)" response = r
    end
    nothing
end

function send_worker()
    while true
        try
            event = take!(main_hub.queued_tasks)
            yield()
            send_envelope(event)
        catch exc
            if main_hub.debug
                @debug "[Sentry]: [ERROR]: Error in send_worker" exception = (exc, catch_backtrace())
            end
        end
    end
end

function clear_queue()
    while isready(main_hub.queued_tasks)
        @info "[Sentry]: waiting for the rest of events are sent..."
        # send_envelope(take!(main_hub.queued_tasks))
        sleep(5)
    end
end


####################################
# * Basic capturing
#----------------------------------



function capture_event(task::TaskPayload)
    main_hub.initialised || return

    push!(main_hub.queued_tasks, task)
end

function capture_message(message, level::LogLevel=Info; kwds...)
    level_str = if level == Warn
        "warning"
    else
        lowercase(string(level))
    end
    capture_message(message, level_str; kwds...)
end
function capture_message(message, level::String; tags=nothing, attachments::Vector=[])
    main_hub.initialised || return

    capture_event(Event(;
        message=(; formatted=message),
        level,
        attachments,
        tags))
end

# This assumes that we are calling from within a catch
capture_exception(exc::Exception) = capture_exception([(exc, catch_backtrace())])
function capture_exception(exceptions=catch_stack())
    main_hub.initialised || return

    formatted_excs = map(exceptions) do (exc, strace)
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
            :stacktrace => (; frames=reverse(frames)))
    end
    capture_event(Event(exception=(; values=formatted_excs),
        level="error"))
end


end # module
