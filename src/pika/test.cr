require "http"

module Pika
  # The structured result returned by `API.request` — the in-process testing
  # harness. Carries everything an assertion needs without binding a socket.
  struct TestResponse
    getter status : Int32
    getter headers : HTTP::Headers
    getter body : String

    def initialize(@status : Int32, @headers : HTTP::Headers, @body : String)
    end

    # Parse the body as JSON. Raises JSON::ParseException on a non-JSON body.
    def json : JSON::Any
      JSON.parse(@body)
    end
  end
end
