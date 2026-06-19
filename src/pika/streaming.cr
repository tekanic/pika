require "json"

module Pika
  # Server-Sent Events writer. Wraps the response IO and emits properly framed
  # `text/event-stream` events, flushing after each so they reach the client
  # immediately. Obtained via the `sse` handler macro:
  #
  #   get do
  #     sse do |stream|
  #       stream.event("hello")
  #       stream.json({tick: 1})
  #       stream.comment("keep-alive")
  #     end
  #   end
  class SSE
    def initialize(@io : IO)
    end

    # Emit one event. Multi-line `data` is split into multiple `data:` lines per
    # the SSE spec. Optional `event` name, `id`, and `retry` (ms) fields.
    def event(data : String, *, event : String? = nil, id : String? = nil, retry : Int32? = nil) : Nil
      if e = event
        @io << "event: " << e << '\n'
      end
      if i = id
        @io << "id: " << i << '\n'
      end
      if r = retry
        @io << "retry: " << r << '\n'
      end
      data.each_line(chomp: true) do |line|
        @io << "data: " << line << '\n'
      end
      @io << '\n'
      @io.flush
    end

    # Emit an event whose data payload is `obj.to_json`.
    def json(obj, **opts) : Nil
      event(obj.to_json, **opts)
    end

    # Emit a comment line (`: ...`) — useful as a keep-alive ping.
    def comment(text : String) : Nil
      @io << ": " << text << '\n' << '\n'
      @io.flush
    end
  end
end
