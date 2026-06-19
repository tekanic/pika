require "../spec_helper"

private def fake_request(router : Pika::Router, method : String, path : String) : HTTP::Server::Context
  req  = HTTP::Request.new(method, path)
  resp = HTTP::Server::Response.new(IO::Memory.new)
  ctx  = HTTP::Server::Context.new(req, resp)
  router.call(ctx)
  ctx
end

# A handler we can hold "in flight" via channels, to drive the drain logic.
module DrainControl
  class_getter started = Channel(Nil).new
  class_getter release = Channel(Nil).new
end

class SlowAPI < Pika::API
  resource :slow do
    get do
      DrainControl.started.send(nil)
      DrainControl.release.receive
      "done"
    end
  end
end

class QuickAPI < Pika::API
  resource :quick do
    get { "ok" }
  end
end

# ---------------------------------------------------------------------------
# #7 — graceful shutdown (drain logic, no sockets/signals)
# ---------------------------------------------------------------------------

describe "graceful shutdown drain" do
  it "reports zero in-flight at rest and drains immediately" do
    QuickAPI.router.inflight.should eq(0)
    QuickAPI.router.await_drain(1.second).should be_true
  end

  it "tracks in-flight requests and waits for them before draining" do
    spawn do
      fake_request(SlowAPI.router, "GET", "/slow")
    end

    # Wait until the handler is executing.
    DrainControl.started.receive
    SlowAPI.router.inflight.should eq(1)

    # Begin draining while the request is still in flight; it must not finish
    # within a short window.
    SlowAPI.router.begin_draining
    SlowAPI.router.draining?.should be_true
    SlowAPI.router.await_drain(50.milliseconds).should be_false

    # Release the handler; in-flight returns to zero and drain completes.
    DrainControl.release.send(nil)
    SlowAPI.router.await_drain(1.second).should be_true
    SlowAPI.router.inflight.should eq(0)
  end

  it "rejects new requests with 503 once draining" do
    QuickAPI.router.begin_draining
    ctx = fake_request(QuickAPI.router, "GET", "/quick")
    ctx.response.status_code.should eq(503)
  end
end
