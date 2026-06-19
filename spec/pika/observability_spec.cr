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
# #6 — observability: request ID, structured log, instrumentation hook
# ---------------------------------------------------------------------------

# Capture instrumentation events here so tests assert without touching STDOUT.
module ObsCapture
  class_property last : Pika::RequestInfo? = nil
  class_property count : Int32 = 0
end

class ObservedAPI < Pika::API
  observability log: false

  instrument do |info|
    ObsCapture.last = info
    ObsCapture.count += 1
  end

  resource :ping do
    get do
      {request_id: request_id}.to_json
    end
  end
end

describe "request ID" do
  it "sets X-Request-Id on the response" do
    response = ObservedAPI.request(:get, "/ping")
    (response.headers["X-Request-Id"]? || "").should_not be_empty
  end

  it "makes the request ID available inside the handler" do
    response = ObservedAPI.request(:get, "/ping")
    response.json["request_id"].as_s.should eq(response.headers["X-Request-Id"])
  end

  it "propagates an incoming X-Request-Id" do
    response = ObservedAPI.request(:get, "/ping", headers: HTTP::Headers{"X-Request-Id" => "abc-123"})
    response.headers["X-Request-Id"]?.should eq("abc-123")
  end
end

describe "instrumentation hook" do
  it "invokes the callback after each request with request facts" do
    before = ObsCapture.count
    fake_request(ObservedAPI.router, "GET", "/ping")
    ObsCapture.count.should eq(before + 1)

    info = ObsCapture.last.not_nil!
    info.method.should eq("GET")
    info.path.should eq("/ping")
    info.status.should eq(200)
    info.request_id.should_not be_empty
    (info.duration >= Time::Span.zero).should be_true
  end
end

describe "structured log line" do
  it "serializes the documented fields as JSON" do
    info = Pika::RequestInfo.new("POST", "/v1/users", 201, 12.milliseconds, "rid-1")
    parsed = JSON.parse(info.to_log_line)
    parsed["method"].as_s.should eq("POST")
    parsed["path"].as_s.should eq("/v1/users")
    parsed["status"].as_i.should eq(201)
    parsed["request_id"].as_s.should eq("rid-1")
    parsed["duration_ms"].as_f.should be_close(12.0, 0.001)
  end
end
