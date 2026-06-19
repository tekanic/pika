require "json"

module Pika
  module OpenAPI
    record ParameterSpec,
      name : String,
      location : String,
      required : Bool,
      schema_type : String

    record RequestBodySpec,
      required_fields : Array({name: String, schema_type: String, format: String}),
      optional_fields : Array({name: String, schema_type: String, format: String})

    # A documented response: a status code, a human description, and an optional
    # reference to a schema in components/schemas (the bare schema name, no $ref
    # prefix — build_paths adds that).
    record ResponseSpec,
      status : Int32,
      description : String,
      schema_ref : String?

    record RouteSpec,
      method : String,
      path : String,
      summary : String,
      parameters : Array(ParameterSpec),
      request_body : RequestBodySpec?,
      responses : Array(ResponseSpec) = [] of ResponseSpec

    # Minimal status-code → reason-phrase map for the codes Pika emits.
    def self.status_description(code : Int32) : String
      case code
      when 200 then "OK"
      when 201 then "Created"
      when 202 then "Accepted"
      when 204 then "No Content"
      when 400 then "Bad Request"
      when 401 then "Unauthorized"
      when 403 then "Forbidden"
      when 404 then "Not Found"
      when 409 then "Conflict"
      when 422 then "Unprocessable Entity"
      when 500 then "Internal Server Error"
      else          "Response"
      end
    end

    # The generic error schema referenced by auto-documented error responses
    # (422 validation, 401/403/404/409 raised errors). Shape mirrors the default
    # RFC 7807 problem document plus the validation `errors` array.
    def self.error_schema : JSON::Any
      props = {
        "type"   => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
        "title"  => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
        "status" => JSON::Any.new({"type" => JSON::Any.new("integer")} of String => JSON::Any),
        "detail" => JSON::Any.new({"type" => JSON::Any.new("string")} of String => JSON::Any),
        "errors" => JSON::Any.new({"type" => JSON::Any.new("array")} of String => JSON::Any),
      } of String => JSON::Any
      JSON::Any.new({
        "type"       => JSON::Any.new("object"),
        "properties" => JSON::Any.new(props),
      } of String => JSON::Any)
    end

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
      description : String = "",
      schemas : Hash(String, JSON::Any) = {} of String => JSON::Any
    ) : String
      doc = {
        "openapi" => JSON::Any.new("3.1.0"),
        "info"    => JSON::Any.new(build_info(title, version, description)),
        "paths"   => JSON::Any.new(build_paths(routes)),
      } of String => JSON::Any
      unless schemas.empty?
        doc["components"] = JSON::Any.new({
          "schemas" => JSON::Any.new(schemas),
        } of String => JSON::Any)
      end
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
          all_fields     = body.required_fields + body.optional_fields
          required_names = body.required_fields.map(&.[:name])
          props = {} of String => JSON::Any
          all_fields.each do |f|
            prop = {"type" => JSON::Any.new(f[:schema_type])} of String => JSON::Any
            prop["format"] = JSON::Any.new(f[:format]) unless f[:format].empty?
            props[f[:name]] = JSON::Any.new(prop)
          end
          # A binary field means the body is multipart, not JSON.
          media = all_fields.any? { |f| f[:format] == "binary" } ? "multipart/form-data" : "application/json"
          op["requestBody"] = JSON::Any.new({
            "required" => JSON::Any.new(true),
            "content"  => JSON::Any.new({
              media => JSON::Any.new({
                "schema" => JSON::Any.new({
                  "type"       => JSON::Any.new("object"),
                  "required"   => JSON::Any.new(required_names.map { |n| JSON::Any.new(n) }),
                  "properties" => JSON::Any.new(props),
                } of String => JSON::Any),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        responses = {} of String => JSON::Any
        if r.responses.empty?
          responses["200"] = JSON::Any.new({"description" => JSON::Any.new("OK")} of String => JSON::Any)
        else
          r.responses.each do |rs|
            entry = {"description" => JSON::Any.new(rs.description)} of String => JSON::Any
            if ref = rs.schema_ref
              entry["content"] = JSON::Any.new({
                "application/json" => JSON::Any.new({
                  "schema" => JSON::Any.new({
                    "$ref" => JSON::Any.new("#/components/schemas/#{ref}"),
                  } of String => JSON::Any),
                } of String => JSON::Any),
              } of String => JSON::Any)
            end
            responses[rs.status.to_s] = JSON::Any.new(entry)
          end
        end
        op["responses"] = JSON::Any.new(responses)

        paths[oa_p][r.method] = JSON::Any.new(op)
      end

      result = {} of String => JSON::Any
      paths.each { |k, v| result[k] = JSON::Any.new(v) }
      result
    end
  end
end
