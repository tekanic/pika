# PoC 3 (revised): Benchmark server — stdlib HTTP::Server + hand-rolled router
#
# No external dependencies. Proves Crystal's built-in HTTP stack hits the
# performance targets without Kemal.
#
# Three endpoints:
#   GET  /static    — pure routing, returns "ok"
#   GET  /json      — JSON serialization
#   POST /validated — JSON body parse + manual coercion
#
# Build: crystal build --release poc/bench/server.cr -o poc/bench/server
# Run:   ./poc/bench/server

require "http/server"
require "json"

# ---------------------------------------------------------------------------
# Minimal router
# ---------------------------------------------------------------------------

alias Handler = HTTP::Server::Context -> String?

record DynRoute,
  method : String,
  segments : Array(String),
  handler : Handler

class Router
  def initialize
    @static  = {} of String => Handler
    @dynamic = [] of DynRoute
  end

  def add(method : String, path : String, &block : Handler)
    if path.includes?(':')
      @dynamic << DynRoute.new(method, path.split('/'), block)
    else
      @static["#{method}\0#{path}"] = block
    end
  end

  def route(ctx : HTTP::Server::Context)
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
    ctx.response.print("Not Found")
  end
end

# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

router = Router.new

router.add("GET", "/static") do |env|
  env.response.content_type = "text/plain"
  "ok"
end

router.add("GET", "/json") do |env|
  env.response.content_type = "application/json"
  {id: 1, name: "Alice", email: "alice@example.com"}.to_json
end

router.add("POST", "/validated") do |env|
  env.response.content_type = "application/json"
  body = env.request.body.try(&.gets_to_end) || ""
  begin
    data  = JSON.parse(body)
    email = data["email"]?.try(&.as_s)
    name  = data["name"]?.try(&.as_s)
    age   = data["age"]?.try(&.as_i)

    errors = [] of String
    errors << "email required"        if email.nil?
    errors << "email must contain @"  if email && !email.includes?('@')
    errors << "name required"         if name.nil?
    errors << "age must be 13-120"    if age && (age < 13 || age > 120)

    if errors.empty?
      {ok: true, email: email, name: name, age: age}.to_json
    else
      env.response.status_code = 422
      {errors: errors}.to_json
    end
  rescue JSON::ParseException
    env.response.status_code = 400
    {error: "invalid JSON"}.to_json
  end
end

# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

server = HTTP::Server.new do |ctx|
  router.route(ctx)
end

address = server.bind_tcp 3000
puts "Listening on http://#{address}"
server.listen
