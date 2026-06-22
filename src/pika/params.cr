require "json"
require "http"
require "./error"
require "./upload"
require "./format"

module Pika
  # Extracts request parameters, searching query string, path params (populated
  # by the router), and the body. Bodies are decoded per Content-Type:
  #   application/json                   → object keys
  #   application/x-www-form-urlencoded  → form fields
  #   multipart/form-data                → text fields + uploaded files
  #   application/x-msgpack              → object keys (types preserved)
  module Params
    alias Parsed = {raw: Hash(String, String), files: Hash(String, UploadedFile)}

    # Full extraction: scalar/text fields in :raw, uploaded files in :files.
    def self.parse(env : HTTP::Server::Context) : Parsed
      raw   = {} of String => String
      files = {} of String => UploadedFile

      env.request.query_params.each do |k, v|
        raw[k] = v
      end

      ct = env.request.headers["Content-Type"]? || ""
      if ct.includes?("application/json")
        parse_json_body(env, raw)
      elsif ct.includes?("application/x-www-form-urlencoded")
        body = env.request.body.try(&.gets_to_end) || ""
        URI::Params.parse(body).each { |k, v| raw[k] = v } unless body.empty?
      elsif ct.includes?("multipart/form-data")
        parse_multipart(env, raw, files)
      elsif ct.includes?("msgpack")
        parse_msgpack_body(env, raw)
      end

      {raw: raw, files: files}
    end

    # Back-compat: just the text/scalar fields.
    def self.from_env(env : HTTP::Server::Context) : Hash(String, String)
      parse(env)[:raw]
    end

    private def self.parse_json_body(env : HTTP::Server::Context, raw : Hash(String, String)) : Nil
      body = env.request.body.try(&.gets_to_end) || ""
      return if body.empty?
      begin
        absorb_object(JSON.parse(body), raw)
      rescue JSON::ParseException
        raise Pika::BadRequestError.new("Malformed JSON body")
      end
    end

    private def self.parse_msgpack_body(env : HTTP::Server::Context, raw : Hash(String, String)) : Nil
      bytes = env.request.body.try(&.getb_to_end)
      return unless bytes && !bytes.empty?
      begin
        absorb_object(Pika::Serializer.from_msgpack(bytes), raw)
      rescue ex : Pika::Error
        raise ex
      rescue
        raise Pika::BadRequestError.new("Malformed MessagePack body")
      end
    end

    # Flatten a decoded top-level object into the raw param hash. Scalars become
    # their string form; arrays and nested objects become JSON strings, matching
    # how Array(T) and Pika.object params are validated.
    private def self.absorb_object(any : JSON::Any, raw : Hash(String, String)) : Nil
      obj = any.as_h?
      return unless obj
      obj.each do |k, v|
        raw[k] = case r = v.raw
                  when Int64   then r.to_s
                  when Float64 then r.to_s
                  when Bool    then r.to_s
                  when String  then r
                  else              v.to_json
                  end
      end
    end

    private def self.parse_multipart(env : HTTP::Server::Context,
                                     raw : Hash(String, String),
                                     files : Hash(String, UploadedFile)) : Nil
      HTTP::FormData.parse(env.request) do |part|
        if fn = part.filename
          files[part.name] = UploadedFile.new(
            filename:     fn,
            content_type: part.headers["Content-Type"]? || "application/octet-stream",
            content:      part.body.gets_to_end.to_slice,
          )
        else
          raw[part.name] = part.body.gets_to_end
        end
      end
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
