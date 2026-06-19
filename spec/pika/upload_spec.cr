require "../spec_helper"

private def multipart(fields : Hash(String, String), files : Hash(String, {String, String})) : {String, String}
  io = IO::Memory.new
  builder = HTTP::FormData::Builder.new(io)
  fields.each { |k, v| builder.field(k, v) }
  files.each do |name, meta|
    builder.file(name, IO::Memory.new(meta[1]),
      HTTP::FormData::FileMetadata.new(filename: meta[0]))
  end
  builder.finish
  {io.to_s, builder.content_type}
end

# ---------------------------------------------------------------------------
# #4 — file uploads / input content negotiation
# ---------------------------------------------------------------------------

class UploadAPI < Pika::API
  resource :avatars do
    params do
      requires title  : String
      requires avatar : Pika::UploadedFile
    end
    post do
      {
        title:    declared_params.title,
        filename: declared_params.avatar.filename,
        size:     declared_params.avatar.size,
        content:  declared_params.avatar.gets_to_string,
      }.to_json
    end
  end

  resource :forms do
    params do
      requires name  : String
      requires count : Int32
    end
    post do
      {name: declared_params.name, count: declared_params.count}.to_json
    end
  end
end

describe "multipart/form-data uploads" do
  it "parses text fields and a file into declared_params" do
    body, ct = multipart({"title" => "headshot"}, {"avatar" => {"me.png", "PNGDATA"}})
    response = UploadAPI.request(:post, "/avatars", body: body, headers: HTTP::Headers{"Content-Type" => ct})
    response.status.should eq(200)
    response.json["title"].as_s.should eq("headshot")
    response.json["filename"].as_s.should eq("me.png")
    response.json["content"].as_s.should eq("PNGDATA")
    response.json["size"].as_i.should eq("PNGDATA".bytesize)
  end

  it "returns 422 when a required file is missing" do
    body, ct = multipart({"title" => "headshot"}, {} of String => {String, String})
    response = UploadAPI.request(:post, "/avatars", body: body, headers: HTTP::Headers{"Content-Type" => ct})
    response.status.should eq(422)
    response.body.should contain("is required")
  end
end

describe "application/x-www-form-urlencoded bodies" do
  it "parses urlencoded fields into declared_params with coercion" do
    response = UploadAPI.request(:post, "/forms", body: "name=widget&count=7",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status.should eq(200)
    response.json["name"].as_s.should eq("widget")
    response.json["count"].as_i.should eq(7)
  end

  it "rejects malformed urlencoded coercion with 422" do
    response = UploadAPI.request(:post, "/forms", body: "name=widget&count=notanint",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"})
    response.status.should eq(422)
  end
end

describe "OpenAPI representation of uploads" do
  doc = JSON.parse(UploadAPI.openapi_doc)

  it "represents the file param as multipart with type string / format binary" do
    rb = doc["paths"]["/avatars"]["post"]["requestBody"]["content"]
    rb.as_h.has_key?("multipart/form-data").should be_true
    avatar = rb["multipart/form-data"]["schema"]["properties"]["avatar"]
    avatar["type"].as_s.should eq("string")
    avatar["format"].as_s.should eq("binary")
  end
end
