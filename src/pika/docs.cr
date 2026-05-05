module Pika
  # Serves interactive API documentation powered by Scalar.
  #
  # Mount via the `docs` macro on any Pika::API subclass:
  #
  #   class MyAPI < Pika::API
  #     info title: "My API", version: "1.0.0"
  #     docs at: "/docs"
  #   end
  #
  # GET /docs          → Scalar HTML UI
  # GET /docs/openapi.json → OpenAPI 3.1 JSON spec
  module Docs
    def self.scalar_html(spec_url : String) : String
      <<-HTML
      <!doctype html>
      <html lang="en">
      <head>
        <title>API Reference</title>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
      </head>
      <body>
        <script
          id="api-reference"
          data-url="#{spec_url}">
        </script>
        <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
      </body>
      </html>
      HTML
    end
  end
end
