require "../spec_helper"

# ---------------------------------------------------------------------------
# v0.11 — async / streaming responses (chunked + SSE)
# ---------------------------------------------------------------------------

class StreamAPI < Pika::API
  resource :events do
    get do
      sse do |stream|
        stream.event("hello")
        stream.json({n: 1})
        stream.event("multi\nline", event: "update", id: "7")
        stream.comment("keep-alive")
      end
    end
  end

  resource :chunks do
    get do
      env.response.content_type = "text/plain"
      stream do |io|
        io << "a\n"
        io.flush
        io << "b\n"
        io.flush
      end
    end
  end

  # Async producer: a fiber pushes events into the stream.
  resource :async_events do
    get do
      sse do |stream|
        ch = Channel(Int32).new
        spawn do
          3.times { |i| ch.send(i) }
          ch.close
        end
        while value = ch.receive?
          stream.json({tick: value})
        end
      end
    end
  end
end

describe "SSE streaming" do
  it "sets the text/event-stream content type and no-cache" do
    r = StreamAPI.request(:get, "/events")
    r.headers["Content-Type"].should contain("text/event-stream")
    r.headers["Cache-Control"]?.should eq("no-cache")
  end

  it "frames a plain data event" do
    r = StreamAPI.request(:get, "/events")
    r.body.should contain("data: hello\n\n")
  end

  it "frames a JSON event" do
    r = StreamAPI.request(:get, "/events")
    r.body.should contain(%(data: {"n":1}\n\n))
  end

  it "splits multi-line data and includes event/id fields" do
    r = StreamAPI.request(:get, "/events")
    r.body.should contain("event: update\nid: 7\ndata: multi\ndata: line\n\n")
  end

  it "emits comment keep-alive lines" do
    r = StreamAPI.request(:get, "/events")
    r.body.should contain(": keep-alive\n\n")
  end
end

describe "chunked streaming" do
  it "streams a raw body written incrementally" do
    r = StreamAPI.request(:get, "/chunks")
    r.headers["Content-Type"].should contain("text/plain")
    r.body.should eq("a\nb\n")
  end
end

describe "async producer into SSE" do
  it "streams events pushed from a spawned fiber" do
    r = StreamAPI.request(:get, "/async_events")
    r.body.should contain(%(data: {"tick":0}\n\n))
    r.body.should contain(%(data: {"tick":1}\n\n))
    r.body.should contain(%(data: {"tick":2}\n\n))
  end
end
