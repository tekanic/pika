require "../spec_helper"

private def ctx_with(accept : String = "", query : String = "") : HTTP::Server::Context
  path = query.empty? ? "/x" : "/x?#{query}"
  req = HTTP::Request.new("GET", path)
  req.headers["Accept"] = accept unless accept.empty?
  HTTP::Server::Context.new(req, HTTP::Server::Response.new(IO::Memory.new))
end

# ---------------------------------------------------------------------------
# Serializer — XML
# ---------------------------------------------------------------------------

describe "Pika::Serializer.to_xml" do
  it "renders an object as nested elements under a root" do
    xml = Pika::Serializer.to_xml(JSON.parse(%({"id":1,"name":"gadget"})))
    xml.should start_with(%(<?xml version="1.0" encoding="UTF-8"?>))
    xml.should contain("<response>")
    xml.should contain("<id>1</id>")
    xml.should contain("<name>gadget</name>")
    xml.should contain("</response>")
  end

  it "renders arrays as repeated <item> elements" do
    xml = Pika::Serializer.to_xml(JSON.parse(%({"tags":["a","b"]})))
    xml.should contain("<tags><item>a</item><item>b</item></tags>")
  end

  it "escapes XML special characters" do
    xml = Pika::Serializer.to_xml(JSON.parse(%({"v":"a&b<c>d"})))
    xml.should contain("<v>a&amp;b&lt;c&gt;d</v>")
  end

  it "renders null as a self-closing element" do
    xml = Pika::Serializer.to_xml(JSON.parse(%({"x":null})))
    xml.should contain("<x/>")
  end
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
  all = [:json, :xml, :msgpack]

  it "defaults to JSON" do
    Pika::Serializer.negotiate(ctx_with, all).should eq(:json)
  end

  it "selects XML from the Accept header" do
    Pika::Serializer.negotiate(ctx_with(accept: "application/xml"), all).should eq(:xml)
  end

  it "selects MessagePack from the Accept header" do
    Pika::Serializer.negotiate(ctx_with(accept: "application/x-msgpack"), all).should eq(:msgpack)
  end

  it "honours ?format= override" do
    Pika::Serializer.negotiate(ctx_with(query: "format=xml"), all).should eq(:xml)
  end

  it "falls back to JSON for a format not in the allowed set" do
    Pika::Serializer.negotiate(ctx_with(accept: "application/xml"), [:json]).should eq(:json)
  end
end

# ---------------------------------------------------------------------------
# End-to-end through the API
# ---------------------------------------------------------------------------

class FormatAPI < Pika::API
  formats :json, :xml, :msgpack

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

  it "returns XML when the client asks for it" do
    r = FormatAPI.request(:get, "/widgets", headers: HTTP::Headers{"Accept" => "application/xml"})
    r.headers["Content-Type"].should contain("application/xml")
    r.body.should contain("<name>gadget</name>")
    r.body.should contain("<tags><item>a</item><item>b</item></tags>")
  end

  it "returns MessagePack when the client asks for it" do
    r = FormatAPI.request(:get, "/widgets", headers: HTTP::Headers{"Accept" => "application/x-msgpack"})
    r.headers["Content-Type"].should contain("application/x-msgpack")
    # 4-entry map → fixmap header 0x80 | 4 = 0x84
    r.body.bytes.first.should eq(0x84)
  end

  it "honours the ?format= query override" do
    r = FormatAPI.request(:get, "/widgets", query: "format=xml")
    r.headers["Content-Type"].should contain("application/xml")
  end
end
