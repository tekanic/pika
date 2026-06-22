require "http/server"
require "uuid"
require "./versioning"

module Pika
  alias Handler = HTTP::Server::Context -> String?

  # A single versioned handler attached to a route.
  record RouteEntry,
    handler  : Handler,
    version  : String,
    strategy : VersionStrategy,
    vendor   : String

  record DynRoute,
    method   : String,
    path     : String,
    segments : Array(String),
    entry    : RouteEntry

  class Router
    def initialize
      # Multiple versioned entries can share the same method+path key.
      @static  = {} of String => Array(RouteEntry)
      @dynamic = [] of DynRoute
      @inflight = Atomic(Int32).new(0)
      @draining = false
    end

    # Optional CORS policy; set via the API `cors` macro.
    property cors : Pika::CORS? = nil

    # Optional observability config; set via the API `observability`/`instrument` macros.
    property observability : Pika::Observability? = nil

    # Number of requests currently executing inside a handler.
    def inflight : Int32
      @inflight.get
    end

    def draining? : Bool
      @draining
    end

    # Stop accepting new requests. In-flight requests are unaffected; further
    # requests receive 503 until the process exits.
    def begin_draining : Nil
      @draining = true
    end

    # Block (cooperatively) until in-flight requests drain to zero or the
    # timeout elapses. Returns true if fully drained, false on timeout.
    def await_drain(timeout : Time::Span) : Bool
      deadline = Time.instant + timeout
      while @inflight.get > 0
        return false if Time.instant >= deadline
        sleep 10.milliseconds
      end
      true
    end

    def add(method : String, path : String,
            version : String = "",
            strategy : VersionStrategy = VersionStrategy::Path,
            vendor : String = "",
            &block : Handler)
      entry = RouteEntry.new(
        handler:  block,
        version:  version,
        strategy: strategy,
        vendor:   vendor,
      )
      if path.includes?(':')
        @dynamic << DynRoute.new(method, path, path.split('/'), entry)
      else
        key = "#{method}\0#{path}"
        @static[key] ||= [] of RouteEntry
        @static[key] << entry
      end
    end

    # Yields (method, path, version, strategy, vendor, handler) for every route.
    # Used by `mount` to copy routes between APIs.
    def each_route(&block : String, String, String, VersionStrategy, String, Handler ->)
      @static.each do |key, entries|
        parts = key.split('\0', 2)
        entries.each do |e|
          block.call(parts[0], parts[1], e.version, e.strategy, e.vendor, e.handler)
        end
      end
      @dynamic.each do |r|
        block.call(r.method, r.path, r.entry.version, r.entry.strategy, r.entry.vendor, r.entry.handler)
      end
    end

    def call(ctx : HTTP::Server::Context)
      # CORS: answer preflight directly, and stamp actual responses.
      if cors = @cors
        origin = ctx.request.headers["Origin"]?
        if ctx.request.method == "OPTIONS" && ctx.request.headers.has_key?("Access-Control-Request-Method")
          cors.apply_preflight(ctx, origin)
          return
        end
        cors.apply_actual(ctx, origin)
      end

      # Observability: generate/propagate a request ID before anything else so
      # handlers and downstream logs can see it.
      obs = @observability
      request_id = ""
      if obs
        request_id = ctx.request.headers["X-Request-Id"]? || UUID.random.to_s
        ctx.request.headers["X-Request-Id"] = request_id
        ctx.response.headers["X-Request-Id"] = request_id
      end

      # Reject new work once draining has begun so in-flight requests can finish.
      if @draining
        ctx.response.status_code = 503
        ctx.response.content_type = "application/problem+json"
        ctx.response.print({type: "#{Pika::ErrorFormatter::RFC7807.base_uri}/service-unavailable", title: "Service Unavailable", status: 503}.to_json)
        return
      end

      # Only read the clock when something will consume the timing.
      started = obs ? Time.instant : nil
      @inflight.add(1)
      begin
        dispatch(ctx)
      ensure
        @inflight.sub(1)
      end

      if obs && (t = started)
        obs.record(Pika::RequestInfo.new(
          ctx.request.method, ctx.request.path, ctx.response.status_code,
          Time.instant - t, request_id,
        ))
      end
    end

    private def dispatch(ctx : HTTP::Server::Context)
      method = ctx.request.method
      path   = ctx.request.path

      # Static routes — find first entry whose version matches the request.
      if entries = @static["#{method}\0#{path}"]?
        entries.each do |entry|
          if version_match?(entry, ctx)
            result = entry.handler.call(ctx)
            ctx.response.print(result) if result
            return
          end
        end
      end

      # Dynamic routes.
      parts = path.split('/')
      @dynamic.each do |r|
        next unless r.method == method && r.segments.size == parts.size
        matched    = true
        path_params = {} of String => String
        r.segments.each_with_index do |seg, i|
          if seg.starts_with?(':')
            path_params[seg[1..]] = parts[i]
          elsif seg != parts[i]
            matched = false
            break
          end
        end
        next unless matched
        next unless version_match?(r.entry, ctx)
        path_params.each { |k, v| ctx.request.query_params[k] = v }
        result = r.entry.handler.call(ctx)
        ctx.response.print(result) if result
        return
      end

      ctx.response.status_code = 404
      ctx.response.content_type = "application/problem+json"
      ctx.response.print({type: "#{Pika::ErrorFormatter::RFC7807.base_uri}/not-found", title: "Not Found", status: 404}.to_json)
    end

    private def version_match?(entry : RouteEntry, ctx : HTTP::Server::Context) : Bool
      # Unversioned routes always match.
      return true if entry.version.empty?
      case entry.strategy
      when VersionStrategy::Path
        # Version is already baked into the URL — the path match is sufficient.
        true
      else
        Pika.version_from_request(ctx, entry.strategy, entry.vendor) == entry.version
      end
    end
  end
end
