require "../src/pika"

class HelloAPI < Pika::API
  resource :greet do
    desc "Say hello"
    params do
      requires name : String, length: 1..100
      optional excited : Bool = false
    end
    get do
      greeting = "Hello, #{declared_params.name}#{declared_params.excited ? "!!!" : "."}"
      {message: greeting}.to_json
    end
  end
end

# Emit OpenAPI for the single route
puts "OpenAPI paths:"
puts HelloAPI.openapi

# Uncomment to start the server:
# HelloAPI.run
