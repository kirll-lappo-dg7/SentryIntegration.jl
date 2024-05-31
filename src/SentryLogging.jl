using Logging

import ..SentryIntegration

struct SentryLogger <: AbstractLogger
    min_level::LogLevel
end

function Logging.handle_message(logger::SentryLogger, level::LogLevel, message, args...; kwargs...)

    exception = get(kwargs, :exception, nothing)
    exception = resolve_exception(exception)

    if (isnothin(message) || message == "")
        message = exception.message
    end

    SentryIntegration.capture_message(message, level, exception)
end

function resolve_exception(exception)
    if (isnothing(exception))
        return nothing
    end

    (e, b) = exception
    if (!isnothing(e) && isa(e, Exception) && !isnothing(b))
        return (e, b)
    end

    if (isa(exception, Exception))
        return exception
    end

    if (isa(exception, String))
        return ErrorException(exception)
    end

    if (isa(e, String))
        return ErrorException(e)
    end

    return nothing
end

function Logging.shouldlog(logger::SentryLogger, arg...)
    true
end

function Logging.min_enabled_level(logger::SentryLogger)
    logger.min_level
end

function Logging.catch_exceptions(logger::SentryLogger)
    true
end
