# PoC 2: OpenAPI Emission via Macro Metadata Accumulation
#
# Goal: prove that metadata can be accumulated across desc/params/verb calls
# and emitted as a valid OpenAPI 3.1 fragment.
#
# Strategy: one `routes do...end` block whose AST is parsed inline within a
# single macro expansion, so all state lives in macro-local variables and
# there are no cross-call ordering issues (the lesson from PoC 1).
#
# Run: crystal poc/openapi/openapi_poc.cr

require "json"

module Pika
  module OpenAPI
    record RouteSpec,
      method : String,
      path : String,
      summary : String,
      parameters : Array(ParameterSpec),
      request_body : RequestBodySpec?

    record ParameterSpec,
      name : String,
      location : String,
      required : Bool,
      schema_type : String

    record RequestBodySpec,
      required_fields : Array({name: String, schema_type: String}),
      optional_fields : Array({name: String, schema_type: String})

    def self.emit_paths(routes : Array(RouteSpec)) : String
      paths = {} of String => Hash(String, JSON::Any)

      routes.each do |r|
        paths[r.path] ||= {} of String => JSON::Any

        op = {} of String => JSON::Any
        op["summary"] = JSON::Any.new(r.summary)
        op["operationId"] = JSON::Any.new("#{r.method}_#{r.path.gsub(/[^a-z0-9]/i, "_")}")

        unless r.parameters.empty?
          op["parameters"] = JSON::Any.new(r.parameters.map { |p|
            JSON::Any.new({
              "name"     => JSON::Any.new(p.name),
              "in"       => JSON::Any.new(p.location),
              "required" => JSON::Any.new(p.required),
              "schema"   => JSON::Any.new({"type" => JSON::Any.new(p.schema_type)} of String => JSON::Any),
            } of String => JSON::Any)
          })
        end

        if body = r.request_body
          required_names = body.required_fields.map(&.[:name])
          all_props = {} of String => JSON::Any
          (body.required_fields + body.optional_fields).each do |f|
            all_props[f[:name]] = JSON::Any.new({"type" => JSON::Any.new(f[:schema_type])} of String => JSON::Any)
          end
          op["requestBody"] = JSON::Any.new({
            "required" => JSON::Any.new(true),
            "content"  => JSON::Any.new({
              "application/json" => JSON::Any.new({
                "schema" => JSON::Any.new({
                  "type"       => JSON::Any.new("object"),
                  "required"   => JSON::Any.new(required_names.map { |n| JSON::Any.new(n) }),
                  "properties" => JSON::Any.new(all_props),
                } of String => JSON::Any),
              } of String => JSON::Any),
            } of String => JSON::Any),
          } of String => JSON::Any)
        end

        paths[r.path][r.method] = JSON::Any.new(op)
      end

      result = {} of String => JSON::Any
      paths.each { |k, v| result[k] = JSON::Any.new(v) }
      JSON::Any.new(result).to_json
    end
  end

  module DSL
    macro routes(&block)
      {% route_list   = [] of Nil %}
      {% pending_desc = "" %}
      {% pending_body = [] of Nil %}

      {% if block.body.is_a?(Expressions) %}
        {% stmts = block.body.expressions %}
      {% else %}
        {% stmts = [block.body] %}
      {% end %}

      {% for expr in stmts %}
        {% if expr.is_a?(Call) %}

          {% if expr.name == "desc" %}
            {% pending_desc = expr.args[0] %}

          {% elsif expr.name == "params" %}
            {% pending_body = [] of Nil %}
            {% pb = expr.block.body %}
            {% if pb.is_a?(Expressions) %}
              {% pexprs = pb.expressions %}
            {% else %}
              {% pexprs = [pb] %}
            {% end %}
            {% for pexpr in pexprs %}
              {% if pexpr.is_a?(Call) && (pexpr.name == "requires" || pexpr.name == "optional") %}
                {% decl = pexpr.args[0] %}
                {% ts = decl.type.stringify %}
                {% if ts == "Int32" || ts == "Int64" %}
                  {% oa = "integer" %}
                {% elsif ts == "Float32" || ts == "Float64" %}
                  {% oa = "number" %}
                {% elsif ts == "Bool" %}
                  {% oa = "boolean" %}
                {% else %}
                  {% oa = "string" %}
                {% end %}
                {% pending_body << {name: decl.var.stringify, oa_type: oa, required: pexpr.name == "requires"} %}
              {% end %}
            {% end %}

          {% elsif expr.name == "get" || expr.name == "post" || expr.name == "put" || expr.name == "patch" || expr.name == "delete" || expr.name == "head" %}
            {% path        = expr.args[0] %}
            {% path_params = [] of Nil %}
            {% for seg in path.split("/") %}
              {% if seg.starts_with?(":") %}
                {% path_params << {name: seg.gsub(/:/, ""), location: "path", required: true, oa_type: "string"} %}
              {% end %}
            {% end %}

            {% route_list << {
                 method:      expr.name.stringify,
                 path:        path,
                 summary:     pending_desc,
                 path_params: path_params,
                 body_params: pending_body,
               } %}
            {% pending_desc = "" %}
            {% pending_body = [] of Nil %}
          {% end %}

        {% end %}
      {% end %}

      # Generate openapi_paths from the fully-populated route_list.
      # Everything is a macro-local variable so there are no class-constant
      # or cross-call ordering issues.
      def self.openapi_paths : String
        Pika::OpenAPI.emit_paths(
          [
            {% for r in route_list %}
              {% has_body = !r[:body_params].empty? && (r[:method] == "post" || r[:method] == "put" || r[:method] == "patch") %}
              {% params_code = r[:path_params] %}
              {% if has_body %}
                Pika::OpenAPI::RouteSpec.new(
                  method:  {{ r[:method] }},
                  path:    {{ r[:path] }},
                  summary: {{ r[:summary] }},
                  parameters: [
                    {% for p in params_code %}
                      Pika::OpenAPI::ParameterSpec.new(name: {{ p[:name] }}, location: {{ p[:location] }}, required: {{ p[:required] }}, schema_type: {{ p[:oa_type] }}),
                    {% end %}
                  ] of Pika::OpenAPI::ParameterSpec,
                  request_body: Pika::OpenAPI::RequestBodySpec.new(
                    required_fields: [
                      {% for p in r[:body_params] %}{% if p[:required] %}{name: {{ p[:name] }}, schema_type: {{ p[:oa_type] }}},{% end %}{% end %}
                    ] of {name: String, schema_type: String},
                    optional_fields: [
                      {% for p in r[:body_params] %}{% unless p[:required] %}{name: {{ p[:name] }}, schema_type: {{ p[:oa_type] }}},{% end %}{% end %}
                    ] of {name: String, schema_type: String},
                  ),
                ),
              {% else %}
                Pika::OpenAPI::RouteSpec.new(
                  method:  {{ r[:method] }},
                  path:    {{ r[:path] }},
                  summary: {{ r[:summary] }},
                  parameters: [
                    {% for p in params_code %}
                      Pika::OpenAPI::ParameterSpec.new(name: {{ p[:name] }}, location: {{ p[:location] }}, required: {{ p[:required] }}, schema_type: {{ p[:oa_type] }}),
                    {% end %}
                  ] of Pika::OpenAPI::ParameterSpec,
                  request_body: nil,
                ),
              {% end %}
            {% end %}
          ] of Pika::OpenAPI::RouteSpec
        )
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Test subject
# ---------------------------------------------------------------------------

class TestAPI
  include Pika::DSL

  routes do
    desc "Get a user"
    params do
      requires id : Int32
    end
    get "/users/:id"

    desc "Create a user"
    params do
      requires email : String
      requires name : String
      optional age : Int32
    end
    post "/users"

    desc "Update a user"
    params do
      optional name : String
      optional age : Int32
    end
    patch "/users/:id"

    desc "Delete a user"
    delete "/users/:id"
  end
end

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

puts "PoC 2: OpenAPI Emission via Macro Metadata Accumulation"
puts "-" * 40

json_str = TestAPI.openapi_paths
puts "Generated OpenAPI paths JSON:"
puts json_str

paths = JSON.parse(json_str)

# 1. All four operations present
raise "missing GET /users/:id"    unless paths["/users/:id"]?.try(&.["get"]?)
raise "missing PATCH /users/:id"  unless paths["/users/:id"]?.try(&.["patch"]?)
raise "missing DELETE /users/:id" unless paths["/users/:id"]?.try(&.["delete"]?)
raise "missing POST /users"       unless paths["/users"]?.try(&.["post"]?)
puts "✓ All four operations present"

# 2. desc correctly associated with route
summary = paths["/users/:id"]["get"]["summary"].as_s
raise "wrong summary: #{summary}" unless summary == "Get a user"
puts "✓ desc correctly associated with route"

# 3. Path parameter extracted from route pattern
param = paths["/users/:id"]["get"]["parameters"][0]
raise "path param name wrong"     unless param["name"].as_s == "id"
raise "path param location wrong" unless param["in"].as_s == "path"
puts "✓ Path parameter extracted from route pattern"

# 4. Request body schema derived from params block
body = paths["/users"]["post"]["requestBody"]
props = body["content"]["application/json"]["schema"]["properties"]
raise "email missing"       unless props["email"]?
raise "name missing"        unless props["name"]?
raise "email type wrong"    unless props["email"]["type"].as_s == "string"
puts "✓ Request body schema derived from params block"

# 5. Required vs optional fields correct
required = body["content"]["application/json"]["schema"]["required"].as_a.map(&.as_s)
raise "email not required"         unless required.includes?("email")
raise "name not required"          unless required.includes?("name")
raise "age should not be required" if     required.includes?("age")
puts "✓ Required vs optional fields correct"

# 6. DELETE has no request body
raise "DELETE should have no body" if paths["/users/:id"]["delete"]["requestBody"]?
puts "✓ DELETE route has no request body"

puts
puts "All assertions passed."
