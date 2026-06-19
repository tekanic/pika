require "../spec_helper"

# ---------------------------------------------------------------------------
# #5 — in-process testing harness (API.request)
# ---------------------------------------------------------------------------

class HarnessAPI < Pika::API
  version "v1"

  resource :users do
    params do
      requires name : String
    end
    post do
      status 201
      header "X-Created", "yes"
      {created: true, name: declared_params.name}.to_json
    end

    get do
      {list: [] of String}.to_json
    end

    route_param :id do
      delete do
        nil
      end
    end
  end
end

describe "API.request harness" do
  it "runs a POST through the full chain and returns a structured response" do
    response = HarnessAPI.request(:post, "/v1/users", json: {name: "x"})
    response.status.should eq(201)
    response.json["created"].as_bool.should be_true
    response.json["name"].as_s.should eq("x")
  end

  it "exposes response headers set by the handler" do
    response = HarnessAPI.request(:post, "/v1/users", json: {name: "x"})
    response.headers["X-Created"]?.should eq("yes")
  end

  it "surfaces validation failures as a 422" do
    response = HarnessAPI.request(:post, "/v1/users", json: {} of String => String)
    response.status.should eq(422)
  end

  it "handles a GET with no body" do
    response = HarnessAPI.request(:get, "/v1/users")
    response.status.should eq(200)
    response.json["list"].as_a.should be_empty
  end

  it "reflects the verb-default 204 on an empty delete" do
    response = HarnessAPI.request(:delete, "/v1/users/7")
    response.status.should eq(204)
  end

  it "returns 404 for an unknown path without a socket" do
    response = HarnessAPI.request(:get, "/v1/nope")
    response.status.should eq(404)
  end

  it "accepts a raw query string" do
    response = HarnessAPI.request(:get, "/v1/users", query: "page=2")
    response.status.should eq(200)
  end
end
