# Sentry Integration

This package allows a production environment to take advantage of
[Sentry](https://sentry.io/), a error monitoring, release tracking and
transaction tracing platform.

This package has been used internally by Synchronous as a
Sentry API equivalent to the Python/Javascript APIs. It is far from fully
featured, however it includes the basics, such as:
- exception reporting,
- tags,
- transaction/span traces

## Quick Setup

1. Set Sentry-related environment variables:

```shell
SENTRY_DSN="https://################.ingest.sentry.io/############"
SENTRY_RELEASE="package@1.0.0"
SENTRY_ENVIRONMENT="Production"
```

2. Add SentryIntegration package to your project

3. Call `init()` method **once** in your application

```julia
using SentryIntegration;

SentryIntegration.init()
```

4. Integrate `SentryLogger` into you logging setup:

```julia
using Logging: global_logger
using LoggingExtras: TeeLogger
using SentryIntegration.Logger: SentryLogger;

# Send message both to your loggers setup AND sentry
# But you can set up any logger composition you want
function apply_sentry_logger(logger)
    TeeLogger(
        logger,
        SentryLogger(LogLevel(Error)),
    )
end

logger = global_logger()
logger = apply_sentry_logger(logger)
global_logger(logger)
```

5. Catch exceptions and log them using deafult `Logging` package

```julia
try
    # your code here
catch e
    @error "Error at doing job" exception=(e, catch_backtrace())
end
```

## Debug Sdk

### Log Messages

You can enable more log messages to detect problems with Sentry Sdk.

```shell
SENTRY_JULIASDK__DEBUG_MODE=1
```

Also can be done in code:

```julia
using SentryIntegration;

SentryIntegration.init(; debug_mode=true)
```

### Dry Mode

You can enable dry mode to enable Sentry Sdk, but no event will be sent to Sentry servers.

```shell
SENTRY_JULIASDK__DRY_MODE=1
```

Also can be done in code:

```julia
using SentryIntegration;

SentryIntegration.init(; dry_mode=true)
```

## Usage

On start of your app, you need to initialise Sentry. If the environment variable
`SENTRY_DSN` is set, this is used by default:
```julia
SentryIntegration.init()
```
otherwise you should pass in the DSN as a variable
```julia
SentryIntegration.init("https://0000000000000000000000000000000000000000.ingest.sentry.io/0000000")
```

OPTIONAL: you can also assign tags that are relevant to your environment. For example:
```julia
SentryIntegration.set_tag("customer", customer)
SentryIntegration.set_tag("release", string(VERSION))
SentryIntegration.set_tag("environment", get(ENV, "RUN_ENV", "unset"))
```

Messages are sent out via `capture_exception` and `capture_message`:

```julia
# At a high level in your app/tasks (to catch as many unhandled exceptions as
# possible)
try
    core_loop()
catch exc
    capture_exception(exc)
    # Maybe rethrow here
end
```

```julia
# Plain info
capture_message("Boring info message")
```

```julia
# A warning to sentry
capture_message("An external REST request was received for an API ($api_name) that is unknown",
                Warn)
```
```julia
# A error to sentry
capture_message("Should not have got here!", Error)
```
```julia
# A warning to sentry, including an attachment.
capture_message("Noticed an 'errors' field in the GQL REST return:",
                Warn,
                attachments=[(;command, response)])
```
```julia
# A message with different tags and attachments
spec_desc = "Specification for structure"
script_desc = "Something more specific"
msg = "Spec failed: $spec_desc ::: $script_desc"
json_data = "{ ... }"
query_string = "DROP TABLES ;"
capture_message(msg, Warn ;
                attachments=[json_data, query_string],
                tags = (; spec_desc,
                          script_desc,
                          graph=g_tag))
```

## Transaction/span tracing

This is a more recent feature of Sentry to trace the execution of a query across
multiple services, e.g. frontend -> authentication layer -> backend server ->
backend database. You can create these with a context-manager style

```julia
return_value_from_inner = SentryIntegration.start_transaction(;
                            name="Name of overall transaction",
                            op="span name, e.g. 'handle web request'",
                            tags=[:url => some_url]) do t
    # Inner function whose logical operation is captured by the name "op" and
    # whose time is to be recorded. This is a "span" in Sentry.
    some_func()
    SentryIntegration.start_transaction(; op="database query") do t
        # This is a nested span in the transaction.
    end
end
```

It is possible to assign or reuse a `trace_id` and `parent_span_id` if these
have been passed from a service (e.g. a frontend) to track transactions across
multiple services.

It is also possible to call `start_transaction` as a regular function call (i.e.
without the context-manager style) to be able to preserve the `Transaction` and
pass it to spawned tasks. In this case, it is necessary to call
`finish_transaction` on the transaction manually:

```julia
t_persist = start_transaction(; name = "MyApp",
                                op = "lifetime",
                                trace_id=passed_in_trace_id)

@async seperate_task(client, details, t_persist)
# ...
# Inside of seperate_task:
function separate_task(client, details, t)
    # This makes the task automatically nest future transactions underneath the
    # passed in transaction, as if this were a context manager.
    SentryIntegration.set_task_transaction(t)

    start_transaction(...) do t2
        #...
    end

    SentryIntegration.finish_transaction(t)
end
```
