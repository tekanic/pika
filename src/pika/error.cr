require "json"

module Pika
  class Error < Exception
    getter status : Int32

    def initialize(message : String, @status : Int32 = 500)
      super(message)
    end
  end

  class ValidationError < Error
    getter fields : Array({field: String, message: String})

    def initialize(@fields : Array({field: String, message: String}))
      super("Validation failed", 422)
    end
  end

  class NotFoundError < Error
    def initialize(message : String = "Not found")
      super(message, 404)
    end
  end

  class UnauthorizedError < Error
    def initialize(message : String = "Unauthorized")
      super(message, 401)
    end
  end

  class ForbiddenError < Error
    def initialize(message : String = "Forbidden")
      super(message, 403)
    end
  end

  class ConflictError < Error
    def initialize(message : String = "Conflict")
      super(message, 409)
    end
  end

  # ---------------------------------------------------------------------------
  # Pluggable error formatter interface
  #
  # Each formatter module exposes two methods:
  #   format_validation(env, error : ValidationError) : String
  #   format_error(env, error : Error) : String
  #
  # Select the active formatter per-API with:
  #   error_formatter :rfc7807   # default
  #   error_formatter :grape
  #   error_formatter :jsonapi
  # ---------------------------------------------------------------------------

  module ErrorFormatter
    module RFC7807
      extend self

      def format_validation(env : HTTP::Server::Context, error : Pika::ValidationError) : String
        env.response.status_code = 422
        env.response.content_type = "application/problem+json"
        {
          type:   "about:blank",
          title:  "Validation Failed",
          status: 422,
          detail: "Request failed validation.",
          errors: error.fields,
        }.to_json
      end

      def format_error(env : HTTP::Server::Context, error : Pika::Error) : String
        env.response.status_code = error.status
        env.response.content_type = "application/problem+json"
        {
          type:   "about:blank",
          title:  error.message,
          status: error.status,
        }.to_json
      end
    end

    # Grape-style: {"error": "message"} / {"errors": ["field message", ...]}
    module Grape
      extend self

      def format_validation(env : HTTP::Server::Context, error : Pika::ValidationError) : String
        env.response.status_code = 422
        env.response.content_type = "application/json"
        msgs = error.fields.map { |f| f[:field] == "base" ? f[:message] : "#{f[:field]} #{f[:message]}" }
        {error: msgs.join(", ")}.to_json
      end

      def format_error(env : HTTP::Server::Context, error : Pika::Error) : String
        env.response.status_code = error.status
        env.response.content_type = "application/json"
        {error: error.message}.to_json
      end
    end

    # JSON:API style: {"errors": [{"title": ..., "detail": ..., "status": "422"}]}
    module JSONAPI
      extend self

      def format_validation(env : HTTP::Server::Context, error : Pika::ValidationError) : String
        env.response.status_code = 422
        env.response.content_type = "application/vnd.api+json"
        entries = error.fields.map do |f|
          {title: f[:field], detail: f[:message], status: "422"}
        end
        {errors: entries}.to_json
      end

      def format_error(env : HTTP::Server::Context, error : Pika::Error) : String
        env.response.status_code = error.status
        env.response.content_type = "application/vnd.api+json"
        {errors: [{title: error.message, status: error.status.to_s}]}.to_json
      end
    end
  end
end
