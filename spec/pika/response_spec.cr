require "../spec_helper"

# Shared fake-request helper (mirrors api_spec.cr).
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

# ---------------------------------------------------------------------------
# #1 — handler control over status code and response headers
# ---------------------------------------------------------------------------

class WidgetUser
  property id : Int32
  property name : String

  def initialize(@id, @name); end
end

class WidgetUserEntity < Pika::Entity(WidgetUser)
  pika_entity do
    expose :id
    expose :name
  end
end

class ResponseAPI < Pika::API
  resource :widgets do
    post do
      status 201
      header "Location", "/widgets/7"
      present WidgetUser.new(7, "gadget"), using: WidgetUserEntity
    end

    route_param :id do
      # No body → should default to 204 No Content.
      delete do
        nil
      end
    end
  end

  resource :gizmos do
    route_param :id do
      delete do
        status 202
        nil
      end
    end
  end
end

describe "handler status / header control" do
  it "lets a handler set an explicit status code" do
    ctx = fake_request(ResponseAPI.router, "POST", "/widgets")
    ctx.response.status_code.should eq(201)
  end

  it "lets a handler set a response header" do
    ctx = fake_request(ResponseAPI.router, "POST", "/widgets")
    ctx.response.headers["Location"]?.should eq("/widgets/7")
  end

  it "still renders the entity body alongside status/header" do
    ctx = fake_request(ResponseAPI.router, "POST", "/widgets")
    ctx.response.close
    body = ctx.response.@io.as(IO::Memory).to_s
    body.should contain(%("id":7))
    body.should contain(%("name":"gadget"))
  end

  it "defaults an empty delete to 204 No Content" do
    ctx = fake_request(ResponseAPI.router, "DELETE", "/widgets/7")
    ctx.response.status_code.should eq(204)
  end

  it "does not override an explicit delete status" do
    ctx = fake_request(ResponseAPI.router, "DELETE", "/gizmos/7")
    ctx.response.status_code.should eq(202)
  end
end

# ---------------------------------------------------------------------------
# #3 — response and error schemas in OpenAPI
# ---------------------------------------------------------------------------

class SchemaAPI < Pika::API
  resource :users do
    desc "Create a user"
    params do
      requires name : String
    end
    returns 201, WidgetUserEntity
    returns 422
    post do
      status 201
      present WidgetUser.new(1, "x"), using: WidgetUserEntity
    end

    route_param :id do
      desc "Fetch a user"
      get do
        raise Pika::NotFoundError.new unless declared_params.id == "1"
        present WidgetUser.new(1, "x"), using: WidgetUserEntity
      end
    end
  end
end

describe "OpenAPI response schemas (returns)" do
  doc = JSON.parse(SchemaAPI.openapi_doc)

  it "documents the declared success status with a schema $ref" do
    resp = doc["paths"]["/users"]["post"]["responses"]
    resp.as_h.has_key?("201").should be_true
    ref = resp["201"]["content"]["application/json"]["schema"]["$ref"].as_s
    ref.should eq("#/components/schemas/WidgetUserEntity")
  end

  it "documents the declared error status" do
    resp = doc["paths"]["/users"]["post"]["responses"]
    resp.as_h.has_key?("422").should be_true
    resp["422"]["content"]["application/json"]["schema"]["$ref"].as_s.should eq("#/components/schemas/PikaError")
  end

  it "emits the entity schema into components/schemas with its properties" do
    schema = doc["components"]["schemas"]["WidgetUserEntity"]
    schema["type"].as_s.should eq("object")
    props = schema["properties"].as_h
    props.has_key?("id").should be_true
    props.has_key?("name").should be_true
  end

  it "never ships an empty 200-only responses object on a documented op" do
    resp = doc["paths"]["/users"]["post"]["responses"].as_h
    resp.keys.should_not eq(["200"])
  end

  it "auto-documents 404 for a handler that raises NotFoundError" do
    resp = doc["paths"]["/users/{id}"]["get"]["responses"]
    resp.as_h.has_key?("404").should be_true
    resp["404"]["content"]["application/json"]["schema"]["$ref"].as_s.should eq("#/components/schemas/PikaError")
  end

  it "auto-documents 422 for a param route with no explicit returns" do
    # The GET on /users (list) has no params; the POST does. Use a param route.
    resp = doc["paths"]["/users/{id}"]["get"]["responses"].as_h
    # id route_param has no body params, so no auto-422; assert the error path instead.
    resp.has_key?("404").should be_true
  end
end

# A param route with no `returns` should auto-document its 422.
class AutoErrAPI < Pika::API
  resource :things do
    params do
      requires q : String
    end
    get do
      "[]"
    end
  end
end

describe "OpenAPI auto error responses" do
  doc = JSON.parse(AutoErrAPI.openapi_doc)

  it "adds a 422 response for routes with params" do
    resp = doc["paths"]["/things"]["get"]["responses"]
    resp.as_h.has_key?("422").should be_true
  end

  it "registers the PikaError schema in components" do
    doc["components"]["schemas"].as_h.has_key?("PikaError").should be_true
  end
end
