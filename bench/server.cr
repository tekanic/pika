require "../src/pika"

class BenchAPI < Pika::API
  resource :bench do
    # Static route — string return, no allocation
    route_param :kind do
      get do
        case declared_params.kind
        when "static"
          "ok"
        when "json"
          {status: "ok", ts: Time.utc.to_unix}.to_json
        else
          "unknown"
        end
      end
    end

    desc "Validated params"
    params do
      requires name  : String
      requires count : Int32
    end
    post do
      {echo: declared_params.name, n: declared_params.count}.to_json
    end
  end
end

reuse = ENV["REUSE_PORT"]? == "1"
port  = (ENV["PORT"]? || "3000").to_i
BenchAPI.run(port: port, reuse_port: reuse)
