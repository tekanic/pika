require "../spec_helper"

# ---------------------------------------------------------------------------
# Inbound MessagePack request-body parsing
# ---------------------------------------------------------------------------

class InboundAPI < Pika::API
  resource :things do
    params do
      requires name : String
      requires age  : Int32
      optional nums : Array(Int32)
    end
    post do
      {name: declared_params.name, age: declared_params.age, nums: declared_params.nums}.to_json
    end
  end
end

private def msgpack(obj) : String
  String.new(Pika::Serializer.to_msgpack(JSON.parse(obj.to_json)))
end

# ---- Decoder units --------------------------------------------------------

describe "Pika::Serializer.from_msgpack" do
  it "round-trips a mixed structure losslessly" do
    sample = JSON.parse(%({"a":1,"b":-7,"c":1.5,"d":"hi","e":true,"f":null,"g":[1,2,3],"h":{"x":"y"}}))
    Pika::Serializer.from_msgpack(Pika::Serializer.to_msgpack(sample)).should eq(sample)
  end

  it "decodes the documented fixmap example" do
    bytes = Bytes[0x81, 0xa1, 0x61, 0x01]   # {"a":1}
    any = Pika::Serializer.from_msgpack(bytes)
    any["a"].as_i.should eq(1)
  end
end

# ---- End-to-end through the API -------------------------------------------

describe "MessagePack request bodies" do
  it "decodes a MessagePack body into declared_params" do
    r = InboundAPI.request(:post, "/things",
      body: msgpack({name: "ada", age: 30, nums: [2, 5]}),
      headers: HTTP::Headers{"Content-Type" => "application/x-msgpack"})
    r.status.should eq(200)
    r.json["name"].as_s.should eq("ada")
    r.json["age"].as_i.should eq(30)
    r.json["nums"].as_a.map(&.as_i).should eq([2, 5])
  end

  it "validates a MessagePack body (missing required field → 422)" do
    r = InboundAPI.request(:post, "/things",
      body: msgpack({name: "ada"}),
      headers: HTTP::Headers{"Content-Type" => "application/x-msgpack"})
    r.status.should eq(422)
  end
end
