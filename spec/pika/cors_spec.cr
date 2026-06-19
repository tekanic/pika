require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String,
                         headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Server::Context
  req  = HTTP::Request.new(method, path, headers)
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx  = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

# ---------------------------------------------------------------------------
# #8 — CORS
# ---------------------------------------------------------------------------

class AllowlistCORSAPI < Pika::API
  cors origins: ["https://app.example.com"],
       methods: ["GET", "POST"],
       headers: ["Content-Type", "Authorization"],
       credentials: true

  resource :things do
    get { "[]" }
  end
end

class WildcardCORSAPI < Pika::API
  cors

  resource :open do
    get { "[]" }
  end
end

describe "CORS allow-list policy" do
  it "echoes an allowed origin on an actual request" do
    h = HTTP::Headers{"Origin" => "https://app.example.com"}
    ctx = fake_request(AllowlistCORSAPI.router, "GET", "/things", h)
    ctx.response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
    ctx.response.headers["Access-Control-Allow-Credentials"]?.should eq("true")
  end

  it "omits CORS headers for a disallowed origin" do
    h = HTTP::Headers{"Origin" => "https://evil.example.com"}
    ctx = fake_request(AllowlistCORSAPI.router, "GET", "/things", h)
    ctx.response.headers.has_key?("Access-Control-Allow-Origin").should be_false
    ctx.response.status_code.should eq(200)
  end

  it "handles a preflight OPTIONS request with 204 and allow headers" do
    h = HTTP::Headers{
      "Origin"                        => "https://app.example.com",
      "Access-Control-Request-Method" => "POST",
    }
    ctx = fake_request(AllowlistCORSAPI.router, "OPTIONS", "/things", h)
    ctx.response.status_code.should eq(204)
    ctx.response.headers["Access-Control-Allow-Methods"]?.should eq("GET, POST")
    ctx.response.headers["Access-Control-Allow-Headers"]?.should eq("Content-Type, Authorization")
    ctx.response.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
  end
end

describe "CORS wildcard policy" do
  it "returns * for any origin without credentials" do
    h = HTTP::Headers{"Origin" => "https://anywhere.example.com"}
    ctx = fake_request(WildcardCORSAPI.router, "GET", "/open", h)
    ctx.response.headers["Access-Control-Allow-Origin"]?.should eq("*")
  end

  it "answers preflight for a wildcard policy" do
    h = HTTP::Headers{
      "Origin"                        => "https://anywhere.example.com",
      "Access-Control-Request-Method" => "GET",
    }
    ctx = fake_request(WildcardCORSAPI.router, "OPTIONS", "/open", h)
    ctx.response.status_code.should eq(204)
    ctx.response.headers["Access-Control-Allow-Origin"]?.should eq("*")
  end
end
