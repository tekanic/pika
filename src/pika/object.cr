require "json"

module Pika
  # Pika.object — define a nested-object type usable as a param type.
  #
  #   Pika.object LineItem do
  #     field sku : String
  #     field qty : Int32
  #     field note : String? = nil
  #   end
  #
  #   params do
  #     requires customer : String
  #     requires address  : Address           # nested object
  #     requires items    : Array(LineItem)   # array of nested objects
  #   end
  #
  # The generated struct mixes in JSON::Serializable (so Pika can coerce it from
  # the request body) and exposes `pika_schema_name` / `pika_openapi_schema` so
  # the type is emitted into the OpenAPI `components/schemas` and `$ref`-ed from
  # request bodies. Fields are scalars (String, Int*, Float*, Bool, and nilable
  # variants); model deeper nesting by composing multiple Pika.object types.
  macro object(name, &block)
    struct {{ name.id }}
      include JSON::Serializable

      {% fields = [] of Nil %}
      {% if block.body.is_a?(Expressions) %}
        {% stmts = block.body.expressions %}
      {% else %}
        {% stmts = [block.body] %}
      {% end %}
      {% for stmt in stmts %}
        {% if stmt.is_a?(Call) && stmt.name == "field" %}
          {% decl = stmt.args[0] %}
          {% fields << {name: decl.var, type: decl.type, default: decl.value,
                        has_default: !decl.value.is_a?(Nop)} %}
        {% end %}
      {% end %}

      {% for f in fields %}
        {% if f[:has_default] %}
          property {{ f[:name] }} : {{ f[:type] }} = {{ f[:default] }}
        {% else %}
          property {{ f[:name] }} : {{ f[:type] }}
        {% end %}
      {% end %}

      def self.pika_schema_name : String
        {{ name.id.stringify.split("::").last }}
      end

      def self.pika_openapi_schema : JSON::Any
        _props    = {} of String => JSON::Any
        _required = [] of JSON::Any
        {% for f in fields %}
          {% ft = f[:type].stringify %}
          {% if ft.includes?("Int32") || ft.includes?("Int64") %}{% oa = "integer" %}
          {% elsif ft.includes?("Float") %}{% oa = "number" %}
          {% elsif ft.includes?("Bool") %}{% oa = "boolean" %}
          {% else %}{% oa = "string" %}{% end %}
          _props[{{ f[:name].stringify }}] = JSON::Any.new({"type" => JSON::Any.new({{ oa }})} of String => JSON::Any)
          {% nilable_f = ft.includes?("Nil") || ft.ends_with?("?") %}
          {% unless nilable_f || f[:has_default] %}
            _required << JSON::Any.new({{ f[:name].stringify }})
          {% end %}
        {% end %}
        _h = {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new(_props),
        } of String => JSON::Any
        _h["required"] = JSON::Any.new(_required) unless _required.empty?
        JSON::Any.new(_h)
      end
    end
  end
end
