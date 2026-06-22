require "../spec_helper"

private def ctx_with(accept : String = "", query : String = "") : HTTP::Server::Context
  path = query.empty? ? "/x" : "/x?#{query}"
  req = HTTP::Request.new("GET", path)
  req.headers["Accept"] = accept unless accept.empty?
  HTTP::Server::Context.new(req, HTTP::Server::Response.new(IO::Memory.new))
end

# ---------------------------------------------------------------------------
# Serializer — MessagePack (assert exact wire bytes)
# ---------------------------------------------------------------------------

describe "Pika::Serializer.to_msgpack" do
  it "encodes a single-key map" do
    Pika::Serializer.to_msgpack(JSON.parse(%({"a":1}))).to_a
      .should eq([0x81, 0xa1, 0x61, 0x01])
  end

  it "encodes a small array" do
    Pika::Serializer.to_msgpack(JSON.parse("[1,2,3]")).to_a
      .should eq([0x93, 0x01, 0x02, 0x03])
  end

  it "encodes booleans and nil" do
    Pika::Serializer.to_msgpack(JSON.parse("true")).to_a.should eq([0xc3])
    Pika::Serializer.to_msgpack(JSON.parse("false")).to_a.should eq([0xc2])
    Pika::Serializer.to_msgpack(JSON.parse("null")).to_a.should eq([0xc0])
  end

  it "encodes a negative fixint" do
    Pika::Serializer.to_msgpack(JSON.parse("-1")).to_a.should eq([0xff])
  end

  it "encodes a fixstr" do
    Pika::Serializer.to_msgpack(JSON.parse(%("hi"))).to_a.should eq([0xa2, 0x68, 0x69])
  end

  it "encodes a large int as int64" do
    bytes = Pika::Serializer.to_msgpack(JSON.parse("1000")).to_a
    bytes.first.should eq(0xd3)
    bytes.size.should eq(9)
  end
end

# ---------------------------------------------------------------------------
# Negotiation
# ---------------------------------------------------------------------------

describe "Pika::Serializer.negotiate" do
  all = [:json, :msgpack]

  it "defaults to JSON" do
    Pika::Serializer.negotiate(ctx_with, all).should eq(:json)
  end

  it "selects MessagePack from the Accept header" do
    Pika::Serializer.negotiate(ctx_with(accept: "application/x-msgpack"), all).should eq(:msgpack)
  end

  it "honours ?format= override" do
    Pika::Serializer.negotiate(ctx_with(query: "format=msgpack"), all).should eq(:msgpack)
  end

  it "falls back to JSON for a format not in the allowed set" do
    Pika::Serializer.negotiate(ctx_with(accept: "application/x-msgpack"), [:json]).should eq(:json)
  end
end

# ---------------------------------------------------------------------------
# End-to-end through the API
# ---------------------------------------------------------------------------

class FormatAPI < Pika::API
  formats :json, :msgpack

  resource :widgets do
    get do
      {id: 1, name: "gadget", tags: ["a", "b"], active: true}.to_json
    end
  end
end

describe "content negotiation through the API" do
  it "returns JSON by default" do
    r = FormatAPI.request(:get, "/widgets")
    r.headers["Content-Type"].should contain("application/json")
    r.json["name"].as_s.should eq("gadget")
  end

  it "returns MessagePack when the client asks for it" do
    r = FormatAPI.request(:get, "/widgets", headers: HTTP::Headers{"Accept" => "application/x-msgpack"})
    r.headers["Content-Type"].should contain("application/x-msgpack")
    # 4-entry map → fixmap header 0x80 | 4 = 0x84
    r.body.bytes.first.should eq(0x84)
  end

  it "honours the ?format= query override" do
    r = FormatAPI.request(:get, "/widgets", query: "format=msgpack")
    r.headers["Content-Type"].should contain("application/x-msgpack")
  end
end
