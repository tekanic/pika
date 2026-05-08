require "../spec_helper"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

private def build_ctx(method : String, path : String,
                      headers : Hash(String, String) = {} of String => String)
  io      = IO::Memory.new
  request = HTTP::Request.new(method, path)
  headers.each { |k, v| request.headers[k] = v }
  response = HTTP::Server::Response.new(io)
  HTTP::Server::Context.new(request, response)
end

# ---------------------------------------------------------------------------
# Path versioning (default, regression guard)
# ---------------------------------------------------------------------------

class PathVersionedAPI < Pika::API
  version "v1"   # using: :path is the default

  resource :items do
    get { "v1 items" }
  end
end

describe "Path versioning" do
  it "routes GET /v1/items" do
    ctx = build_ctx("GET", "/v1/items")
    PathVersionedAPI.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 for unversioned path /items" do
    ctx = build_ctx("GET", "/items")
    PathVersionedAPI.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end
end

# ---------------------------------------------------------------------------
# Header versioning  —  X-Api-Version: v1
# ---------------------------------------------------------------------------

class HeaderV1API < Pika::API
  version "v1", using: :header

  resource :widgets do
    get { "header v1 widgets" }
    post { "header v1 created" }
  end
end

class HeaderV2API < Pika::API
  version "v2", using: :header

  resource :widgets do
    get { "header v2 widgets" }
  end
end

class HeaderVersionedApp < Pika::API
  mount HeaderV1API
  mount HeaderV2API
end

describe "Header versioning" do
  it "serves v1 when X-Api-Version: v1" do
    ctx = build_ctx("GET", "/widgets", {"X-Api-Version" => "v1"})
    HeaderVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "serves v2 when X-Api-Version: v2" do
    ctx = build_ctx("GET", "/widgets", {"X-Api-Version" => "v2"})
    HeaderVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 when header is missing" do
    ctx = build_ctx("GET", "/widgets")
    HeaderVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end

  it "returns 404 when header has an unknown version" do
    ctx = build_ctx("GET", "/widgets", {"X-Api-Version" => "v99"})
    HeaderVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end

  it "routes POST with correct version header" do
    ctx = build_ctx("POST", "/widgets", {"X-Api-Version" => "v1"})
    HeaderVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end
end

# ---------------------------------------------------------------------------
# Accept-header versioning  —  Accept: application/vnd.<vendor>.v1+json
# ---------------------------------------------------------------------------

class AcceptV1API < Pika::API
  version "v1", using: :accept, vendor: "myapp"

  resource :things do
    get { "accept v1 things" }
  end
end

class AcceptV2API < Pika::API
  version "v2", using: :accept, vendor: "myapp"

  resource :things do
    get { "accept v2 things" }
  end
end

class AcceptVersionedApp < Pika::API
  mount AcceptV1API
  mount AcceptV2API
end

describe "Accept-header versioning" do
  it "serves v1 with dot separator: application/vnd.myapp.v1+json" do
    ctx = build_ctx("GET", "/things",
      {"Accept" => "application/vnd.myapp.v1+json"})
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "serves v1 with hyphen separator: application/vnd.myapp-v1+json" do
    ctx = build_ctx("GET", "/things",
      {"Accept" => "application/vnd.myapp-v1+json"})
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "serves v2 with dot separator" do
    ctx = build_ctx("GET", "/things",
      {"Accept" => "application/vnd.myapp.v2+json"})
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 when Accept header is missing" do
    ctx = build_ctx("GET", "/things")
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end

  it "returns 404 when vendor does not match" do
    ctx = build_ctx("GET", "/things",
      {"Accept" => "application/vnd.otherapp.v1+json"})
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end

  it "returns 404 for an unknown version number" do
    ctx = build_ctx("GET", "/things",
      {"Accept" => "application/vnd.myapp.v99+json"})
    AcceptVersionedApp.router.call(ctx)
    ctx.response.status_code.should eq(404)
  end
end

# ---------------------------------------------------------------------------
# Unversioned routes are unaffected
# ---------------------------------------------------------------------------

class UnversionedAPI < Pika::API
  resource :health do
    get { "ok" }
  end
end

describe "Unversioned routes" do
  it "always match regardless of any version header" do
    ctx = build_ctx("GET", "/health", {"X-Api-Version" => "v99"})
    UnversionedAPI.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end

  it "match with no version header" do
    ctx = build_ctx("GET", "/health")
    UnversionedAPI.router.call(ctx)
    ctx.response.status_code.should eq(200)
  end
end
