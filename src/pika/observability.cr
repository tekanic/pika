require "http/server"
require "json"

module Pika
  # A completed request's observable facts, handed to the structured logger and
  # to any instrumentation callback (timing, metrics, tracing).
  struct RequestInfo
    getter method : String
    getter path : String
    getter status : Int32
    getter duration : Time::Span
    getter request_id : String

    def initialize(@method : String, @path : String, @status : Int32,
                   @duration : Time::Span, @request_id : String)
    end

    # The default structured access-log line: one JSON object per request.
    def to_log_line : String
      {
        method:      @method,
        path:        @path,
        status:      @status,
        duration_ms: @duration.total_milliseconds,
        request_id:  @request_id,
      }.to_json
    end
  end

  # Per-API observability configuration, attached to the router. When present,
  # the router generates/propagates a request ID, times the request, emits a
  # structured log line, and invokes the instrumentation extension point.
  class Observability
    property log : Bool
    property instrument : Proc(RequestInfo, Nil)?

    def initialize(@log : Bool = true, @instrument : Proc(RequestInfo, Nil)? = nil)
    end

    def record(info : RequestInfo) : Nil
      puts info.to_log_line if @log
      if cb = @instrument
        cb.call(info)
      end
    end
  end
end
