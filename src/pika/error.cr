require "json"

module Pika
  class Error < Exception
    getter status : Int32

    def initialize(message : String, @status : Int32 = 500)
      super(message)
    end

    # A short, stable slug identifying the *kind* of problem. It builds the
    # RFC 7807 `type` URI and the JSON:API error `code`, so clients can branch
    # on the specific problem rather than just the status. Subclasses override;
    # the base derives a slug from the HTTP status.
    def problem_type : String
      case @status
      when 400 then "bad-request"
      when 401 then "unauthorized"
      when 403 then "forbidden"
      when 404 then "not-found"
      when 409 then "conflict"
      when 422 then "unprocessable-entity"
      when 500 then "internal-error"
      else          "error"
      end
    end
  end

  class ValidationError < Error
    getter fields : Array({field: String, message: String})

    def initialize(@fields : Array({field: String, message: String}))
      super("Validation failed", 422)
    end

    # More specific than the status default ("unprocessable-entity"): two 422s
    # (e.g. validation vs a business rule) get distinct types.
    def problem_type : String
      "validation"
    end

    # The field errors with each message rendered as a full, human-readable
    # sentence — the humanized field name prepended to the predicate, e.g.
    # {field: "first_name", message: "First name is required"}. The `field`
    # key is left untouched for machine use. Cross-field errors (`base`) carry
    # a complete sentence already, so they pass through unchanged.
    def humanized_fields : Array({field: String, message: String})
      @fields.map do |f|
        next f if f[:field] == "base"
        {field: f[:field], message: "#{humanize_field(f[:field])} #{f[:message]}"}
      end
    end

    private def humanize_field(field : String) : String
      field.tr("_", " ").capitalize
    end
  end

  class BadRequestError < Error
    def initialize(message : String = "Bad Request")
      super(message, 400)
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

      # Base for the `type` URI. Combined with each error's `problem_type` slug
      # to form a specific, dereferenceable identifier — e.g. "/problems/validation".
      # Point it at your hosted error docs: `Pika::ErrorFormatter::RFC7807.base_uri = "https://docs.myapp.com/errors"`.
      @@base_uri = "/problems"

      def base_uri : String
        @@base_uri
      end

      def base_uri=(uri : String) : String
        @@base_uri = uri
      end

      def type_uri(error : Pika::Error) : String
        "#{@@base_uri}/#{error.problem_type}"
      end

      def format_validation(env : HTTP::Server::Context, error : Pika::ValidationError) : String
        env.response.status_code = 422
        env.response.content_type = "application/problem+json"
        {
          type:   type_uri(error),
          title:  "Validation Failed",
          status: 422,
          detail: "Request failed validation.",
          errors: error.humanized_fields,
        }.to_json
      end

      def format_error(env : HTTP::Server::Context, error : Pika::Error) : String
        env.response.status_code = error.status
        env.response.content_type = "application/problem+json"
        {
          type:   type_uri(error),
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
        {error: error.humanized_fields.map { |f| f[:message] }.join(", ")}.to_json
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
        entries = error.humanized_fields.map do |f|
          {code: error.problem_type, title: f[:field], detail: f[:message], status: "422"}
        end
        {errors: entries}.to_json
      end

      def format_error(env : HTTP::Server::Context, error : Pika::Error) : String
        env.response.status_code = error.status
        env.response.content_type = "application/vnd.api+json"
        {errors: [{code: error.problem_type, title: error.message, status: error.status.to_s}]}.to_json
      end
    end
  end
end
