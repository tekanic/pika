require "http/server"

module Pika
  alias Handler = HTTP::Server::Context -> String?

  record DynRoute, method : String, path : String, segments : Array(String), handler : Handler

  class Router
    def initialize
      @static  = {} of String => Handler
      @dynamic = [] of DynRoute
    end

    def add(method : String, path : String, &block : Handler)
      if path.includes?(':')
        @dynamic << DynRoute.new(method, path, path.split('/'), block)
      else
        @static["#{method}\0#{path}"] = block
      end
    end

    # Yields {method, path, handler} for every registered route.
    def each_route(&block : String, String, Handler ->)
      @static.each do |key, handler|
        parts = key.split('\0', 2)
        block.call(parts[0], parts[1], handler)
      end
      @dynamic.each do |r|
        block.call(r.method, r.path, r.handler)
      end
    end

    def call(ctx : HTTP::Server::Context)
      method = ctx.request.method
      path   = ctx.request.path

      if h = @static["#{method}\0#{path}"]?
        result = h.call(ctx)
        ctx.response.print(result) if result
        return
      end

      parts = path.split('/')
      @dynamic.each do |r|
        next unless r.method == method && r.segments.size == parts.size
        matched = true
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
        path_params.each { |k, v| ctx.request.query_params[k] = v }
        result = r.handler.call(ctx)
        ctx.response.print(result) if result
        return
      end

      ctx.response.status_code = 404
      ctx.response.content_type = "application/problem+json"
      ctx.response.print({type: "about:blank", title: "Not Found", status: 404}.to_json)
    end
  end
end
