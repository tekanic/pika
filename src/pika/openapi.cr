require "json"

module Pika
  module OpenAPI
    record ParameterSpec,
      name : String,
      location : String,
      required : Bool,
      schema_type : String

    record RequestBodySpec,
      required_fields : Array({name: String, schema_type: String}),
      optional_fields : Array({name: String, schema_type: String})

    record RouteSpec,
      method : String,
      path : String,
      summary : String,
      parameters : Array(ParameterSpec),
      request_body : RequestBodySpec?

    # Convert Vine-style path params (:id) to OpenAPI-style ({id}).
    def self.oa_path(path : String) : String
      path.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/, "{\\1}")
    end

    # Emit just the paths object (retained for backward compat).
    def self.emit_paths(routes : Array(RouteSpec)) : String
      build_paths(routes).to_json
    end

    # Emit a full OpenAPI 3.1 document.
    def self.emit_doc(
      routes : Array(RouteSpec),
      title : String = "API",
      version : String = "1.0.0",
      description : String = ""
    ) : String
      doc = {
        "openapi" => JSON::Any.new("3.1.0"),
        "info"    => JSON::Any.new(build_info(title, version, description)),
        "paths"   => JSON::Any.new(build_paths(routes)),
      } of String => JSON::Any
      JSON::Any.new(doc).to_json
    end

    private def self.build_info(title : String, version : String, description : String) : Hash(String, JSON::Any)
      h = {
        "title"   => JSON::Any.new(title),
        "version" => JSON::Any.new(version),
      } of String => JSON::Any
      h["description"] = JSON::Any.new(description) unless description.empty?
      h
    end

    private def self.build_paths(routes : Array(RouteSpec)) : Hash(String, JSON::Any)
      paths = {} of String => Hash(String, JSON::Any)

      routes.each do |r|
        oa_p = oa_path(r.path)
        paths[oa_p] ||= {} of String => JSON::Any

        op = {} of String => JSON::Any
        op["summary"]     = JSON::Any.new(r.summary) unless r.summary.empty?
        op["operationId"] = JSON::Any.new(
          "#{r.method}_#{oa_p.gsub(/[^a-zA-Z0-9]/, "_").gsub(/_+/, "_").strip("_")}"
        )

        params = r.parameters.map do |p|
          JSON::Any.new({
            "name"     => JSON::Any.new(p.name),
            "in"       => JSON::Any.new(p.location),
            "required" => JSON::Any.new(p.required),
            "schema"   => JSON::Any.new({"type" => JSON::Any.new(p.schema_type)} of String => JSON::Any),
          } of String => JSON::Any)
        end
        op["parameters"] = JSON::Any.new(params) unless params.empty?

        if body = r.request_body
          required_names = body.required_fields.map(&.[:name])
          props = {} of String => JSON::Any
          (body.required_fields + body.optional_fields).each do |f|
            props[f[:name]] = JSON::Any.new({"type" => JSON::Any.new(f[:schema_type])} of String => JSON::Any)
          end
          op["requestBody"] = JSON::Any.new({
            "required" => JSON::Any.new(true),
            "content"  => JSON::Any.new({
              "application/json" => JSON::Any.new({
                "schema" => JSON::Any.new({
                  "type"       => JSON::Any.new("object"),
                  "required"   => JSON::Any.new(required_names.map { |n| JSON::Any.new(n) }),
                  "properties" => JSON::Any.new(props),
                } of String => JSON::Any),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        op["responses"] = JSON::Any.new({
          "200" => JSON::Any.new({"description" => JSON::Any.new("OK")} of String => JSON::Any),
        } of String => JSON::Any)

        paths[oa_p][r.method] = JSON::Any.new(op)
      end

      result = {} of String => JSON::Any
      paths.each { |k, v| result[k] = JSON::Any.new(v) }
      result
    end
  end
end
