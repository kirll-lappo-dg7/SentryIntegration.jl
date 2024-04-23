using Logging

import ..SentryIntegration

struct SentryLogger <: AbstractLogger
    min_level::LogLevel
end

function Logging.handle_message(filelogger::SentryLogger, level::LogLevel, message, args...; kwargs...)

    function resolve_exception(exception)
        if (isnothing(exception))
            return nothing
        end

        if (isa(exception, Exception))
            return exception
        end

        if (isa(exception, String))
            return ErrorException(exception)
        end

        (e, _) = exception
        if (!isnothing(e) && isa(e, Exception))
            return e
        end

        if (isa(e, String))
            return ErrorException(e)
        end

        return nothing
    end

    exception = get(kwargs, :exception, nothing)
    exception = resolve_exception(exception)
    if (isnothing(exception))
        return
    end

    SentryIntegration.capture_exception(exception)
end

function Logging.shouldlog(filelogger::SentryLogger, arg...)
    true
end

function Logging.min_enabled_level(logger::SentryLogger)
    logger.min_level
end

function Logging.catch_exceptions(logger::SentryLogger)
    true
end
