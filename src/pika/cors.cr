require "http/server"

module Pika
  # CORS policy applied by the router. Configure it from an API with the `cors`
  # macro; the router consults it on every request and handles preflight
  # (OPTIONS) automatically.
  #
  #   class MyAPI < Pika::API
  #     cors origins: ["https://app.example.com"],
  #          methods: ["GET", "POST"],
  #          headers: ["Content-Type", "Authorization"],
  #          credentials: true
  #   end
  struct CORS
    getter origins : Array(String)
    getter methods : Array(String)
    getter headers : Array(String)
    getter credentials : Bool
    getter max_age : Int32

    def initialize(@origins : Array(String),
                   @methods : Array(String),
                   @headers : Array(String),
                   @credentials : Bool = false,
                   @max_age : Int32 = 600)
    end

    def wildcard? : Bool
      @origins.includes?("*")
    end

    # The value to echo in Access-Control-Allow-Origin for a given request
    # Origin, or nil if the origin is not permitted. A wildcard policy with
    # credentials echoes the concrete origin (the spec forbids "*" + creds).
    def allow_origin_for(origin : String?) : String?
      if wildcard?
        return @credentials ? origin : "*"
      end
      return nil if origin.nil?
      @origins.includes?(origin) ? origin : nil
    end

    # Headers added to a normal (non-preflight) response.
    def apply_actual(ctx : HTTP::Server::Context, origin : String?) : Nil
      if value = allow_origin_for(origin)
        ctx.response.headers["Access-Control-Allow-Origin"] = value
        ctx.response.headers["Access-Control-Allow-Credentials"] = "true" if @credentials
        ctx.response.headers["Vary"] = "Origin" unless wildcard? && !@credentials
      end
    end

    # Fully handle a preflight OPTIONS request: write CORS headers and a 204.
    def apply_preflight(ctx : HTTP::Server::Context, origin : String?) : Nil
      if value = allow_origin_for(origin)
        ctx.response.headers["Access-Control-Allow-Origin"] = value
        ctx.response.headers["Access-Control-Allow-Methods"] = @methods.join(", ")
        ctx.response.headers["Access-Control-Allow-Headers"] = @headers.join(", ")
        ctx.response.headers["Access-Control-Max-Age"] = @max_age.to_s
        ctx.response.headers["Access-Control-Allow-Credentials"] = "true" if @credentials
        ctx.response.headers["Vary"] = "Origin" unless wildcard? && !@credentials
      end
      ctx.response.status_code = 204
    end
  end
end
