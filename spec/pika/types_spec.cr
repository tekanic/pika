require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String,
                         query : String = "", body : String = "",
                         content_type : String = "application/json") : HTTP::Server::Context
  uri = path + (query.empty? ? "" : "?#{query}")
  req = HTTP::Request.new(method, uri)
  req.headers["Content-Type"] = content_type unless content_type.empty?
  req.body = IO::Memory.new(body) unless body.empty?
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

private def body_of(ctx : HTTP::Server::Context) : String
  ctx.response.close
  ctx.response.@io.as(IO::Memory).to_s
end

# ---------------------------------------------------------------------------
# #2 — richer param types: UUID, Time, Array(scalar)
# ---------------------------------------------------------------------------

class RichTypeAPI < Pika::API
  resource :orders do
    params do
      requires id    : UUID
      requires tags  : Array(String)
      requires qtys  : Array(Int32)
      optional since : Time
    end
    post do
      {
        id:    declared_params.id.to_s,
        tags:  declared_params.tags,
        qtys:  declared_params.qtys,
        since: declared_params.since.try(&.to_rfc3339),
      }.to_json
    end
  end
end

describe "UUID params" do
  it "accepts and coerces a valid UUID" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["a"], qtys: [1]}.to_json)
    ctx.response.status_code.should eq(200)
    body_of(ctx).should contain("550e8400-e29b-41d4-a716-446655440000")
  end

  it "rejects a malformed UUID with 422" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "not-a-uuid", tags: ["a"], qtys: [1]}.to_json)
    ctx.response.status_code.should eq(422)
    body_of(ctx).should contain("must be a valid UUID")
  end
end

describe "Time params" do
  it "accepts and coerces an RFC 3339 timestamp" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["a"], qtys: [1], since: "2026-06-19T12:00:00Z"}.to_json)
    ctx.response.status_code.should eq(200)
    body_of(ctx).should contain("2026-06-19")
  end

  it "rejects a malformed timestamp with 422" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["a"], qtys: [1], since: "not-a-date"}.to_json)
    ctx.response.status_code.should eq(422)
    body_of(ctx).should contain("RFC 3339")
  end

  it "treats an absent optional Time as nil" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["a"], qtys: [1]}.to_json)
    ctx.response.status_code.should eq(200)
  end
end

describe "Array params" do
  it "coerces an Array(String) element-wise" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["x", "y", "z"], qtys: [1]}.to_json)
    ctx.response.status_code.should eq(200)
    body = body_of(ctx)
    body.should contain(%(["x","y","z"]))
  end

  it "coerces an Array(Int32) element-wise" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: ["a"], qtys: [3, 5, 8]}.to_json)
    ctx.response.status_code.should eq(200)
    body_of(ctx).should contain(%([3,5,8]))
  end

  it "rejects a non-array value for an array param" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", tags: "notanarray", qtys: [1]}.to_json)
    ctx.response.status_code.should eq(422)
    body_of(ctx).should contain("must be an array")
  end

  it "reports a required array param when missing" do
    ctx = fake_request(RichTypeAPI.router, "POST", "/orders",
      body: {id: "550e8400-e29b-41d4-a716-446655440000", qtys: [1]}.to_json)
    ctx.response.status_code.should eq(422)
    body_of(ctx).should contain("is required")
  end
end

describe "OpenAPI mapping for rich types" do
  doc = JSON.parse(RichTypeAPI.openapi_doc)

  it "maps Array params to type: array" do
    props = doc["paths"]["/orders"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"].as_h
    props["tags"]["type"].as_s.should eq("array")
    props["qtys"]["type"].as_s.should eq("array")
  end

  it "maps UUID and Time params to type: string" do
    props = doc["paths"]["/orders"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"].as_h
    props["id"]["type"].as_s.should eq("string")
    props["since"]["type"].as_s.should eq("string")
  end
end
