require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String) : HTTP::Server::Context
  req  = HTTP::Request.new(method, path)
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx  = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

# ---------------------------------------------------------------------------
# Test API
# ---------------------------------------------------------------------------

class DocAPI < Pika::API
  info title: "Doc Test API", version: "2.0.0", description: "Testing OpenAPI emission"

  version "v1"

  resource :users do
    desc "List users"
    get do
      "[]"
    end

    desc "Create user"
    params do
      requires name  : String
      optional role  : String = "member"
    end
    post do
      {ok: true}.to_json
    end

    route_param :id do
      desc "Get user by ID"
      get do
        {id: declared_params.id}.to_json
      end
    end
  end

  resource :health do
    get do
      "ok"
    end
  end

  docs at: "/docs"
end

# ---------------------------------------------------------------------------
# Full document structure
# ---------------------------------------------------------------------------

describe "OpenAPI 3.1 document" do
  doc = JSON.parse(DocAPI.openapi_doc)

  it "sets openapi version to 3.1.0" do
    doc["openapi"].as_s.should eq("3.1.0")
  end

  it "includes info from the info macro" do
    doc["info"]["title"].as_s.should eq("Doc Test API")
    doc["info"]["version"].as_s.should eq("2.0.0")
    doc["info"]["description"].as_s.should eq("Testing OpenAPI emission")
  end

  it "has a paths object" do
    doc["paths"].as_h.should_not be_empty
  end

  it "converts :param paths to {param} OpenAPI format" do
    doc["paths"].as_h.keys.should contain("/v1/users/{id}")
    doc["paths"].as_h.keys.should_not contain("/v1/users/:id")
  end

  it "includes summary from desc on the operation" do
    doc["paths"]["/v1/users"]["get"]["summary"].as_s.should eq("List users")
    doc["paths"]["/v1/users"]["post"]["summary"].as_s.should eq("Create user")
    doc["paths"]["/v1/users/{id}"]["get"]["summary"].as_s.should eq("Get user by ID")
  end

  it "includes a 200 response on every operation" do
    doc["paths"]["/v1/users"]["get"]["responses"]["200"]["description"].as_s.should eq("OK")
  end

  it "includes operationId on every operation" do
    op_id = doc["paths"]["/v1/users"]["get"]["operationId"].as_s
    op_id.should_not be_empty
  end
end

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

describe "OpenAPI parameters" do
  doc = JSON.parse(DocAPI.openapi_doc)

  it "includes path parameter for route_param routes" do
    params = doc["paths"]["/v1/users/{id}"]["get"]["parameters"].as_a
    id_param = params.find { |p| p["name"].as_s == "id" }
    id_param.should_not be_nil
    id_param.not_nil!["in"].as_s.should eq("path")
    id_param.not_nil!["required"].as_bool.should be_true
  end

  it "includes requestBody for POST with params" do
    rb = doc["paths"]["/v1/users"]["post"]["requestBody"]
    rb["required"].as_bool.should be_true
    props = rb["content"]["application/json"]["schema"]["properties"].as_h
    props.has_key?("name").should be_true
    props.has_key?("role").should be_true
  end

  it "marks required params as required in requestBody" do
    schema = doc["paths"]["/v1/users"]["post"]["requestBody"]["content"]["application/json"]["schema"]
    required_fields = schema["required"].as_a.map(&.as_s)
    required_fields.should contain("name")
    required_fields.should_not contain("role")
  end
end

# ---------------------------------------------------------------------------
# Default info (no info macro called)
# ---------------------------------------------------------------------------

class MinimalAPI < Pika::API
  resource :ping do
    get do
      "pong"
    end
  end
end

describe "OpenAPI default info" do
  it "uses the class name as title when info is not set" do
    doc = JSON.parse(MinimalAPI.openapi_doc)
    doc["info"]["title"].as_s.should eq("MinimalAPI")
    doc["info"]["version"].as_s.should eq("1.0.0")
  end
end

# ---------------------------------------------------------------------------
# Pika::Docs.scalar_html
# ---------------------------------------------------------------------------

describe "Pika::Docs" do
  it "scalar_html includes the spec URL" do
    html = Pika::Docs.scalar_html("/my/openapi.json")
    html.should contain("/my/openapi.json")
  end

  it "scalar_html references the Scalar CDN script" do
    html = Pika::Docs.scalar_html("/openapi.json")
    html.should contain("scalar")
  end

  it "scalar_html returns valid HTML" do
    html = Pika::Docs.scalar_html("/openapi.json")
    html.should contain("<!doctype html>")
    html.should contain("</html>")
  end
end

# ---------------------------------------------------------------------------
# docs macro — route registration
# ---------------------------------------------------------------------------

describe "docs macro" do
  it "registers GET /docs route" do
    ctx = fake_request(DocAPI.router, "GET", "/docs")
    ctx.response.status_code.should eq(200)
    (ctx.response.headers["Content-Type"]? || "").should contain("text/html")
  end

  it "registers GET /docs/openapi.json route" do
    ctx = fake_request(DocAPI.router, "GET", "/docs/openapi.json")
    ctx.response.status_code.should eq(200)
    (ctx.response.headers["Content-Type"]? || "").should contain("application/json")
  end
end

# ---------------------------------------------------------------------------
# OpenAPI path helper
# ---------------------------------------------------------------------------

describe "Pika::OpenAPI.oa_path" do
  it "converts :param to {param}" do
    Pika::OpenAPI.oa_path("/users/:id").should eq("/users/{id}")
  end

  it "converts multiple params" do
    Pika::OpenAPI.oa_path("/orgs/:org/repos/:repo").should eq("/orgs/{org}/repos/{repo}")
  end

  it "leaves static paths unchanged" do
    Pika::OpenAPI.oa_path("/health").should eq("/health")
  end
end
