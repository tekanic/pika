require "../spec_helper"

describe Pika::Router do
  it "dispatches static routes" do
    router = Pika::Router.new
    called = false
    router.add("GET", "/ping") { |_env| called = true; "pong" }

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/ping")
    response = HTTP::Server::Response.new(io)
    ctx = HTTP::Server::Context.new(request, response)
    router.call(ctx)

    called.should be_true
  end

  it "dispatches dynamic routes and injects path params" do
    router = Pika::Router.new
    captured_id = ""
    router.add("GET", "/users/:id") do |env|
      captured_id = env.request.query_params["id"]
      "got it"
    end

    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/users/42")
    response = HTTP::Server::Response.new(io)
    ctx = HTTP::Server::Context.new(request, response)
    router.call(ctx)

    captured_id.should eq("42")
  end

  it "returns 404 for unknown routes" do
    router = Pika::Router.new
    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/nothing")
    response = HTTP::Server::Response.new(io)
    ctx = HTTP::Server::Context.new(request, response)
    router.call(ctx)

    ctx.response.status_code.should eq(404)
  end
end
