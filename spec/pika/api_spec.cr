require "../spec_helper"

# ---------------------------------------------------------------------------
# Helper — send a fake request through a router and return the context
# ---------------------------------------------------------------------------
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
# version + namespace
# ---------------------------------------------------------------------------

class VersionedAPI < Pika::API
  version "v1"

  resource :status do
    get do
      {ok: true}.to_json
    end
  end
end

class NamespacedAPI < Pika::API
  namespace :admin do
    resource :users do
      get do
        {scope: "admin/users"}.to_json
      end
    end
  end

  resource :health do
    get do
      "ok"
    end
  end
end

describe "version" do
  it "mounts routes under the version prefix" do
    ctx = fake_request(VersionedAPI.router, "GET", "/v1/status")
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 without the version prefix" do
    ctx = fake_request(VersionedAPI.router, "GET", "/status")
    ctx.response.status_code.should eq(404)
  end
end

describe "namespace" do
  it "nests resource under namespace path" do
    ctx = fake_request(NamespacedAPI.router, "GET", "/admin/users")
    ctx.response.status_code.should eq(200)
  end

  it "top-level resource still works alongside namespace" do
    ctx = fake_request(NamespacedAPI.router, "GET", "/health")
    ctx.response.status_code.should eq(200)
  end
end

# ---------------------------------------------------------------------------
# route_param
# ---------------------------------------------------------------------------

class UserAPI < Pika::API
  resource :users do
    get do
      {list: true}.to_json
    end

    post do
      {created: true}.to_json
    end

    route_param :id do
      get do
        {id: declared_params.id}.to_json
      end
    end
  end
end

describe "route_param" do
  it "registers the base resource route" do
    ctx = fake_request(UserAPI.router, "GET", "/users")
    ctx.response.status_code.should eq(200)
  end

  it "registers the route_param route and injects path param" do
    ctx = fake_request(UserAPI.router, "GET", "/users/42")
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 for non-existent sub-paths" do
    ctx = fake_request(UserAPI.router, "DELETE", "/users/42")
    ctx.response.status_code.should eq(404)
  end
end

# ---------------------------------------------------------------------------
# route_param with declared_params (path param in DeclaredParams)
# ---------------------------------------------------------------------------

class ItemAPI < Pika::API
  resource :items do
    route_param :id do
      desc "Get item"
      params do
        optional format : String = "json"
      end
      get do
        {id: declared_params.id, format: declared_params.format}.to_json
      end
    end
  end
end

describe "route_param with params" do
  it "merges path param and query params into declared_params" do
    ctx = fake_request(ItemAPI.router, "GET", "/items/99", query: "format=xml")
    ctx.response.status_code.should eq(200)
  end
end

# ---------------------------------------------------------------------------
# before / after hooks
# ---------------------------------------------------------------------------

class HookedAPI < Pika::API
  before do
    env.response.headers["X-Before"] = "yes"
  end

  after do
    env.response.headers["X-After"] = "yes"
  end

  resource :ping do
    get do
      "pong"
    end
  end
end

class AuthAPI < Pika::API
  before do
    raise Pika::UnauthorizedError.new unless env.request.headers["X-Token"]? == "secret"
  end

  resource :secure do
    get do
      "secret data"
    end
  end
end

describe "before / after hooks" do
  it "before hook sets header on every request" do
    ctx = fake_request(HookedAPI.router, "GET", "/ping")
    ctx.response.headers["X-Before"]?.should eq("yes")
  end

  it "after hook sets header on every request" do
    ctx = fake_request(HookedAPI.router, "GET", "/ping")
    ctx.response.headers["X-After"]?.should eq("yes")
  end

  it "before hook raising Pika::Error returns error response" do
    ctx = fake_request(AuthAPI.router, "GET", "/secure")
    ctx.response.status_code.should eq(401)

    req = HTTP::Request.new("GET", "/secure")
    req.headers["X-Token"] = "secret"
    resp = HTTP::Server::Response.new(IO::Memory.new)
    ctx2 = HTTP::Server::Context.new(req, resp)
    AuthAPI.router.call(ctx2)
    ctx2.response.status_code.should eq(200)
  end
end

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

class HelperAPI < Pika::API
  helpers do
    def self.greet(name : String) : String
      "Hello, #{name}!"
    end
  end

  resource :greet do
    params do
      requires name : String
    end
    get do
      {message: self.greet(declared_params.name)}.to_json
    end
  end
end

describe "helpers" do
  it "class method defined in helpers block is callable from handler" do
    ctx = fake_request(HelperAPI.router, "GET", "/greet", query: "name=World")
    ctx.response.status_code.should eq(200)
  end
end

# ---------------------------------------------------------------------------
# mutually_exclusive / at_least_one_of / exactly_one_of
# ---------------------------------------------------------------------------

class MutexAPI < Pika::API
  resource :contact do
    params do
      optional email : String?
      optional phone : String?
      mutually_exclusive :email, :phone
    end
    post do
      {ok: true}.to_json
    end
  end

  resource :search do
    params do
      optional q : String?
      optional id : Int32?
      at_least_one_of :q, :id
    end
    get do
      {ok: true}.to_json
    end
  end

  resource :pick do
    params do
      optional a : String?
      optional b : String?
      exactly_one_of :a, :b
    end
    get do
      {ok: true}.to_json
    end
  end
end

describe "mutually_exclusive" do
  it "allows only one of the exclusive params" do
    ctx = fake_request(MutexAPI.router, "POST", "/contact",
                       body: {"email" => "a@b.com"}.to_json)
    ctx.response.status_code.should eq(200)
  end

  it "rejects when both exclusive params provided" do
    ctx = fake_request(MutexAPI.router, "POST", "/contact",
                       body: {"email" => "a@b.com", "phone" => "555"}.to_json)
    ctx.response.status_code.should eq(422)
  end

  it "allows neither (both optional)" do
    ctx = fake_request(MutexAPI.router, "POST", "/contact",
                       body: "{}".to_json)
    ctx.response.status_code.should eq(200)
  end
end

describe "at_least_one_of" do
  it "allows when one param provided" do
    ctx = fake_request(MutexAPI.router, "GET", "/search", query: "q=foo")
    ctx.response.status_code.should eq(200)
  end

  it "rejects when neither param provided" do
    ctx = fake_request(MutexAPI.router, "GET", "/search")
    ctx.response.status_code.should eq(422)
  end
end

describe "exactly_one_of" do
  it "allows when exactly one param provided" do
    ctx = fake_request(MutexAPI.router, "GET", "/pick", query: "a=x")
    ctx.response.status_code.should eq(200)
  end

  it "rejects when both params provided" do
    ctx = fake_request(MutexAPI.router, "GET", "/pick", query: "a=x&b=y")
    ctx.response.status_code.should eq(422)
  end

  it "rejects when neither param provided" do
    ctx = fake_request(MutexAPI.router, "GET", "/pick")
    ctx.response.status_code.should eq(422)
  end
end

# ---------------------------------------------------------------------------
# Int64 + Float64 param types
# ---------------------------------------------------------------------------

class TypeAPI < Pika::API
  resource :typed do
    params do
      requires id   : Int64
      requires rate : Float64
    end
    post do
      {id: declared_params.id, rate: declared_params.rate}.to_json
    end
  end
end

describe "Int64 and Float64 params" do
  it "coerces and returns correct types" do
    ctx = fake_request(TypeAPI.router, "POST", "/typed",
                       body: {"id" => 999999999999_i64, "rate" => 3.14}.to_json)
    ctx.response.status_code.should eq(200)
  end

  it "rejects non-numeric input" do
    ctx = fake_request(TypeAPI.router, "POST", "/typed",
                       body: {"id" => "notanumber", "rate" => 3.14}.to_json)
    ctx.response.status_code.should eq(422)
  end
end

# ---------------------------------------------------------------------------
# params_from — derives param struct from PIKA_COLUMNS constant.
# In production, Pika::Clear::Model generates this constant automatically
# via `macro finished`. In tests, we define it manually.
# ---------------------------------------------------------------------------

class ParamsFromModel
  PIKA_COLUMNS = [
    {name: "email",  type_str: "String",  nilable: false, oa_kind: "string"},
    {name: "age",    type_str: "Int32?",  nilable: true,  oa_kind: "integer"},
    {name: "score",  type_str: "Float64", nilable: false, oa_kind: "number"},
    {name: "active", type_str: "Bool",    nilable: false, oa_kind: "boolean"},
  ]

  property email : String = ""
  property age : Int32? = nil
  property score : Float64 = 0.0
  property active : Bool = false

  def initialize; end
end

class ParamsFromAPI < Pika::API
  resource :pf do
    params_from ParamsFromModel
    post do
      {email: declared_params.email, age: declared_params.age}.to_json
    end
  end

  resource :pf_filtered do
    params_from ParamsFromModel, only: [:email, :age]
    post do
      {email: declared_params.email, age: declared_params.age}.to_json
    end
  end
end

describe "params_from" do
  it "accepts a valid request with all required fields" do
    ctx = fake_request(ParamsFromAPI.router, "POST", "/pf",
                       body: {"email" => "a@b.com", "score" => 9.5, "active" => true}.to_json)
    ctx.response.status_code.should eq(200)
    JSON.parse(ctx.response.headers["X-Pika-Body"]? || "{}") rescue nil
  end

  it "rejects a request missing a required field" do
    ctx = fake_request(ParamsFromAPI.router, "POST", "/pf",
                       body: {"age" => 30}.to_json)
    ctx.response.status_code.should eq(422)
  end

  it "treats nilable columns as optional params" do
    ctx = fake_request(ParamsFromAPI.router, "POST", "/pf",
                       body: {"email" => "x@y.com", "score" => 1.0, "active" => false}.to_json)
    ctx.response.status_code.should eq(200)
  end

  it "does not include non-annotated instance vars" do
    ctx = fake_request(ParamsFromAPI.router, "POST", "/pf",
                       body: {"email" => "x@y.com", "score" => 0.0, "active" => false, "_internal" => "injected"}.to_json)
    ctx.response.status_code.should eq(200)
  end

  it "respects the only: filter" do
    ctx = fake_request(ParamsFromAPI.router, "POST", "/pf_filtered",
                       body: {"email" => "a@b.com"}.to_json)
    ctx.response.status_code.should eq(200)
  end
end
