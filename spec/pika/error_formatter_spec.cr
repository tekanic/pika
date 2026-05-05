require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String,
                         body : String = "") : HTTP::Server::Context
  req = HTTP::Request.new(method, path)
  req.headers["Content-Type"] = "application/json" unless body.empty?
  req.body = IO::Memory.new(body) unless body.empty?
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx  = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

private def make_ctx : HTTP::Server::Context
  req  = HTTP::Request.new("GET", "/")
  resp = HTTP::Server::Response.new(IO::Memory.new)
  HTTP::Server::Context.new(req, resp)
end

# ---------------------------------------------------------------------------
# APIs under test (one per formatter)
# ---------------------------------------------------------------------------

class RFC7807API < Pika::API
  error_formatter :rfc7807

  resource :items do
    params do
      requires name : String
    end
    post do
      {ok: true}.to_json
    end
  end

  resource :auth do
    get do
      raise Pika::UnauthorizedError.new
    end
  end
end

class GrapeFormatterAPI < Pika::API
  error_formatter :grape

  resource :items do
    params do
      requires name : String
    end
    post do
      {ok: true}.to_json
    end
  end

  resource :auth do
    get do
      raise Pika::UnauthorizedError.new
    end
  end
end

class JSONAPIFormatterAPI < Pika::API
  error_formatter :jsonapi

  resource :items do
    params do
      requires name : String
    end
    post do
      {ok: true}.to_json
    end
  end

  resource :auth do
    get do
      raise Pika::UnauthorizedError.new
    end
  end
end

# ---------------------------------------------------------------------------
# Direct formatter unit tests
# ---------------------------------------------------------------------------

describe "Pika::ErrorFormatter::RFC7807" do
  it "format_validation returns problem+json with errors array" do
    ctx = make_ctx
    err = Pika::ValidationError.new([{field: "name", message: "is required"}])
    body = Pika::ErrorFormatter::RFC7807.format_validation(ctx, err)
    ctx.response.status_code.should eq(422)
    (ctx.response.headers["Content-Type"]? || "").should contain("problem+json")
    json = JSON.parse(body)
    json["errors"].as_a.size.should be > 0
  end

  it "format_error returns problem+json with title and status" do
    ctx = make_ctx
    err = Pika::UnauthorizedError.new
    body = Pika::ErrorFormatter::RFC7807.format_error(ctx, err)
    ctx.response.status_code.should eq(401)
    json = JSON.parse(body)
    json["status"].as_i.should eq(401)
  end
end

describe "Pika::ErrorFormatter::Grape" do
  it "format_validation returns {error: message}" do
    ctx = make_ctx
    err = Pika::ValidationError.new([{field: "name", message: "is required"}])
    body = Pika::ErrorFormatter::Grape.format_validation(ctx, err)
    ctx.response.status_code.should eq(422)
    json = JSON.parse(body)
    json["error"].as_s.should contain("name")
  end

  it "format_error returns {error: message}" do
    ctx = make_ctx
    err = Pika::UnauthorizedError.new
    body = Pika::ErrorFormatter::Grape.format_error(ctx, err)
    ctx.response.status_code.should eq(401)
    json = JSON.parse(body)
    json["error"].as_s.should eq("Unauthorized")
  end
end

describe "Pika::ErrorFormatter::JSONAPI" do
  it "format_validation returns {errors: [{title, detail, status}]}" do
    ctx = make_ctx
    err = Pika::ValidationError.new([{field: "name", message: "is required"}])
    body = Pika::ErrorFormatter::JSONAPI.format_validation(ctx, err)
    ctx.response.status_code.should eq(422)
    (ctx.response.headers["Content-Type"]? || "").should contain("vnd.api+json")
    json = JSON.parse(body)
    json["errors"][0]["title"].as_s.should eq("name")
    json["errors"][0]["status"].as_s.should eq("422")
  end

  it "format_error returns {errors: [{title, status}]}" do
    ctx = make_ctx
    err = Pika::UnauthorizedError.new
    body = Pika::ErrorFormatter::JSONAPI.format_error(ctx, err)
    ctx.response.status_code.should eq(401)
    json = JSON.parse(body)
    json["errors"][0]["title"].as_s.should eq("Unauthorized")
    json["errors"][0]["status"].as_s.should eq("401")
  end
end

# ---------------------------------------------------------------------------
# Integration — formatter selection via error_formatter macro
# ---------------------------------------------------------------------------

describe "error_formatter integration" do
  it "RFC 7807 API returns 422 with problem+json on validation failure" do
    ctx = fake_request(RFC7807API.router, "POST", "/items", body: "{}")
    ctx.response.status_code.should eq(422)
    (ctx.response.headers["Content-Type"]? || "").should contain("problem+json")
  end

  it "RFC 7807 API returns 401 with problem+json on auth error" do
    ctx = fake_request(RFC7807API.router, "GET", "/auth")
    ctx.response.status_code.should eq(401)
    (ctx.response.headers["Content-Type"]? || "").should contain("problem+json")
  end

  it "Grape API returns 422 with application/json on validation failure" do
    ctx = fake_request(GrapeFormatterAPI.router, "POST", "/items", body: "{}")
    ctx.response.status_code.should eq(422)
    (ctx.response.headers["Content-Type"]? || "").should eq("application/json")
  end

  it "Grape API returns 401 with application/json on auth error" do
    ctx = fake_request(GrapeFormatterAPI.router, "GET", "/auth")
    ctx.response.status_code.should eq(401)
    (ctx.response.headers["Content-Type"]? || "").should eq("application/json")
  end

  it "JSON:API returns 422 with vnd.api+json on validation failure" do
    ctx = fake_request(JSONAPIFormatterAPI.router, "POST", "/items", body: "{}")
    ctx.response.status_code.should eq(422)
    (ctx.response.headers["Content-Type"]? || "").should contain("vnd.api+json")
  end

  it "JSON:API returns 401 with vnd.api+json on auth error" do
    ctx = fake_request(JSONAPIFormatterAPI.router, "GET", "/auth")
    ctx.response.status_code.should eq(401)
    (ctx.response.headers["Content-Type"]? || "").should contain("vnd.api+json")
  end
end
