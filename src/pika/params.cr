require "json"
require "./error"

module Pika
  # Extracts raw values for a given param name from the request, searching
  # query string, JSON body, and path params (query_params is populated with
  # path params by the router).
  module Params
    def self.from_env(env : HTTP::Server::Context) : Hash(String, String)
      raw = {} of String => String

      env.request.query_params.each do |k, v|
        raw[k] = v
      end

      ct = env.request.headers["Content-Type"]? || ""
      if ct.includes?("application/json")
        body = env.request.body.try(&.gets_to_end) || ""
        unless body.empty?
          begin
            parsed = JSON.parse(body)
            if obj = parsed.as_h?
              obj.each do |k, v|
                raw[k] = case v.raw
                          when Int64   then v.as_i64.to_s
                          when Float64 then v.as_f.to_s
                          when Bool    then v.as_bool.to_s
                          when String  then v.as_s
                          else              v.to_json
                          end
              end
            end
          rescue JSON::ParseException
          end
        end
      end

      raw
    end
  end
end

# ---------------------------------------------------------------------------
# params DSL macro
#
# Usage (inside a resource/route context macro):
#
#   params do
#     requires email : String, regexp: /@/
#     optional age   : Int32 = 0, values: 13..120
#   end
#
# Generates a DeclaredParams struct and a validate! class method.
# The generated struct name is passed in via the `struct_name` macro arg so
# each route gets a uniquely-named struct (e.g., PikaP_users_post).
# ---------------------------------------------------------------------------
macro pika_params(struct_name, &block)
  {% params_list = [] of Nil %}

  {% if block.body.is_a?(Expressions) %}
    {% pexprs = block.body.expressions %}
  {% else %}
    {% pexprs = [block.body] %}
  {% end %}

  {% for expr in pexprs %}
    {% if expr.is_a?(Call) && (expr.name == "requires" || expr.name == "optional") %}
      {% decl       = expr.args[0] %}
      {% is_opt     = expr.name == "optional" %}
      {% regexp_val = nil %}
      {% values_val = nil %}
      {% length_val = nil %}
      {% if expr.named_args %}
        {% for na in expr.named_args %}
          {% if na.name == "regexp" %}{% regexp_val = na.value %}{% end %}
          {% if na.name == "values" %}{% values_val = na.value %}{% end %}
          {% if na.name == "length" %}{% length_val = na.value %}{% end %}
        {% end %}
      {% end %}
      {% params_list << {
           name:    decl.var,
           type:    decl.type,
           opt:     is_opt,
           default: decl.value,
           regexp:  regexp_val,
           values:  values_val,
           length:  length_val,
         } %}
    {% end %}
  {% end %}

  struct {{ struct_name.id }}
    {% for p in params_list %}
      {% if p[:opt] && !p[:default].is_a?(Nop) %}
        property {{ p[:name] }} : {{ p[:type] }} = {{ p[:default] }}
      {% else %}
        property {{ p[:name] }} : {{ p[:type] }}
      {% end %}
    {% end %}

    def initialize(
      {% for p in params_list %}
        {% if p[:opt] && !p[:default].is_a?(Nop) %}
          @{{ p[:name] }} : {{ p[:type] }} = {{ p[:default] }},
        {% elsif p[:opt] %}
          @{{ p[:name] }} : {{ p[:type] }},
        {% else %}
          @{{ p[:name] }} : {{ p[:type] }},
        {% end %}
      {% end %}
    )
    end
  end

  def self.validate_{{ struct_name.downcase.id }}!(raw : Hash(String, String)) : {{ struct_name.id }}
    _errors = [] of {field: String, message: String}

    {% for p in params_list %}
      _raw_{{ p[:name] }} = raw[{{ p[:name].stringify }}]?

      {% ts      = p[:type].stringify %}
      {% nilable = ts.includes?("Nil") || ts.ends_with?("?") %}

      {% if ts.includes?("String") %}
        _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}""{% end %}
        if _v = _raw_{{ p[:name] }}
          _val_{{ p[:name] }} = _v

          {% if p[:regexp] %}
            _errors << {field: {{ p[:name].stringify }}, message: "must match #{{{ p[:regexp] }}.source}"} unless _val_{{ p[:name] }}.matches?({{ p[:regexp] }})
          {% end %}
          {% if p[:length] %}
            _errors << {field: {{ p[:name].stringify }}, message: "length must be in #{{{ p[:length] }}}"} unless ({{ p[:length] }}).includes?(_val_{{ p[:name] }}.size)
          {% end %}
        else
          {% unless p[:opt] %}
            _errors << {field: {{ p[:name].stringify }}, message: "is required"}
          {% end %}
        end

      {% elsif ts.includes?("Int32") %}
        _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% elsif !p[:default].is_a?(Nop) %}{{ p[:default] }}{% else %}0{% end %}
        if _v = _raw_{{ p[:name] }}
          _parsed_{{ p[:name] }} = _v.to_i32?
          if _parsed_{{ p[:name] }}
            _val_{{ p[:name] }} = _parsed_{{ p[:name] }}
            {% if p[:values] %}
              _errors << {field: {{ p[:name].stringify }}, message: "must be in #{{{ p[:values] }}}"} unless ({{ p[:values] }}).includes?(_val_{{ p[:name] }}.not_nil!)
            {% end %}
          else
            _errors << {field: {{ p[:name].stringify }}, message: "must be an integer"}
          end
        else
          {% unless p[:opt] %}
            _errors << {field: {{ p[:name].stringify }}, message: "is required"}
          {% end %}
        end

      {% elsif ts.includes?("Float64") %}
        _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}0.0{% end %}
        if _v = _raw_{{ p[:name] }}
          _parsed_{{ p[:name] }} = _v.to_f64?
          if _parsed_{{ p[:name] }}
            _val_{{ p[:name] }} = _parsed_{{ p[:name] }}
          else
            _errors << {field: {{ p[:name].stringify }}, message: "must be a number"}
          end
        else
          {% unless p[:opt] %}
            _errors << {field: {{ p[:name].stringify }}, message: "is required"}
          {% end %}
        end

      {% elsif ts.includes?("Bool") %}
        _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% elsif !p[:default].is_a?(Nop) %}{{ p[:default] }}{% else %}false{% end %}
        if _v = _raw_{{ p[:name] }}
          if _v == "true" || _v == "1"
            _val_{{ p[:name] }} = true
          elsif _v == "false" || _v == "0"
            _val_{{ p[:name] }} = false
          else
            _errors << {field: {{ p[:name].stringify }}, message: "must be true or false"}
          end
        else
          {% unless p[:opt] %}
            _errors << {field: {{ p[:name].stringify }}, message: "is required"}
          {% end %}
        end
      {% end %}
    {% end %}

    raise Pika::ValidationError.new(_errors) unless _errors.empty?

    {{ struct_name.id }}.new(
      {% for p in params_list %}
        {{ p[:name] }}: _val_{{ p[:name] }},
      {% end %}
    )
  end
end
