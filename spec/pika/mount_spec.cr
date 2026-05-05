require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String) : HTTP::Server::Context
  req  = HTTP::Request.new(method, path)
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx  = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

# ---------------------------------------------------------------------------
# Sub-API that will be mounted
# ---------------------------------------------------------------------------

class ProductsAPI < Pika::API
  resource :products do
    get do
      {products: [] of String}.to_json
    end

    route_param :id do
      get do
        {id: declared_params.id}.to_json
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Root API that mounts the sub-API
# ---------------------------------------------------------------------------

class RootMountAPI < Pika::API
  version "v1"
  mount ProductsAPI
end

# ---------------------------------------------------------------------------
# Namespaced mount
# ---------------------------------------------------------------------------

class ShopAPI < Pika::API
  namespace :shop do
    mount ProductsAPI
  end
end

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe "mount" do
  it "copies static routes from the mounted API" do
    ctx = fake_request(RootMountAPI.router, "GET", "/v1/products")
    ctx.response.status_code.should eq(200)
  end

  it "copies dynamic routes from the mounted API" do
    ctx = fake_request(RootMountAPI.router, "GET", "/v1/products/7")
    ctx.response.status_code.should eq(200)
  end

  it "returns 404 for unmounted paths" do
    ctx = fake_request(RootMountAPI.router, "GET", "/products")
    ctx.response.status_code.should eq(404)
  end

  it "applies namespace prefix when mount is inside namespace" do
    ctx = fake_request(ShopAPI.router, "GET", "/shop/products")
    ctx.response.status_code.should eq(200)
  end
end
