require "http/server"
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
      ctx.response.print({type: "about:blank", title: "Not Found", status: 404}.to_json)
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
