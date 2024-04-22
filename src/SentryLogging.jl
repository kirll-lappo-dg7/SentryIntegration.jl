using Logging
using LoggingExtras: TeeLogger

import ..SentryIntegration: capture_exception

struct SerilogLogger <: AbstractLogger
    min_level::LogLevel
end

function Logging.handle_message(filelogger::SerilogLogger, level::LogLevel, message, args...; kwargs...)

    function resolve_exception(exception)
        if (isnothing(exception))
            return nothing
        end

        if (isa(exception, Exception))
            return exception
        end

        (e, _) = exception
        if (!isnothing(e) && isa(e, Exception))
            return e
        end

        return nothing
    end

    exception = get(kwargs, :exception, nothing)
    exception = resolve_exception(exception)
    if (isnothing(exception))
        return
    end

    capture_exception(exception)
end

function Logging.shouldlog(filelogger::SerilogLogger, arg...)
    true
end

function Logging.min_enabled_level(logger::SerilogLogger)
    logger.min_level
end

function Logging.catch_exceptions(logger::SerilogLogger)
    true
end

function apply_sentry_logger(logger)
    TeeLogger(
        logger,
        SerilogLogger(LogLevel(Error)),
    )
end