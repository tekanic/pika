# PoC 1: Params DSL Macro
#
# Run: crystal poc/params/params_poc.cr

module Pika
  class ValidationError < Exception
    getter field_errors : Array(String)

    def initialize(@field_errors : Array(String))
      super("Validation failed: #{@field_errors.join(", ")}")
    end
  end

  module Params
    # Parse the params block body AST directly so all information is available
    # within a single macro expansion pass, avoiding cross-pass ordering issues.
    macro params(&block)
      {% params_list = [] of Nil %}

      {% for expr in block.body.expressions %}
        {% if expr.is_a?(Call) && (expr.name == "requires" || expr.name == "optional") %}
          {% decl = expr.args[0] %}
          {% is_optional = expr.name == "optional" %}

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
               name:     decl.var,
               type:     decl.type,
               optional: is_optional,
               default:  decl.value,
               regexp:   regexp_val,
               values:   values_val,
               length:   length_val,
             } %}
        {% end %}
      {% end %}

      struct DeclaredParams
        {% for p in params_list %}
          {% if p[:optional] %}
            {% unless p[:default].is_a?(Nop) %}
              property {{ p[:name] }} : {{ p[:type] }} = {{ p[:default] }}
            {% else %}
              property {{ p[:name] }} : {{ p[:type] }}
            {% end %}
          {% else %}
            property {{ p[:name] }} : {{ p[:type] }}
          {% end %}
        {% end %}

        def initialize(
          {% for p in params_list %}
            {% if p[:optional] %}
              {% unless p[:default].is_a?(Nop) %}
                @{{ p[:name] }} : {{ p[:type] }} = {{ p[:default] }},
              {% else %}
                @{{ p[:name] }} : {{ p[:type] }} = nil,
              {% end %}
            {% else %}
              @{{ p[:name] }} : {{ p[:type] }},
            {% end %}
          {% end %}
        )
        end
      end

      def self.validate!(raw : Hash(String, String)) : DeclaredParams
        errors = [] of String

        # Presence check for required fields
        {% for p in params_list %}
          {% fname = p[:name].stringify %}
          {% unless p[:optional] %}
            errors << "{{ p[:name] }}: is required" if raw[{{ fname }}]?.nil?
          {% end %}
        {% end %}

        raise Pika::ValidationError.new(errors) unless errors.empty?

        # Coerce and validate constraints
        {% for p in params_list %}
          {% fname = p[:name].stringify %}
          {% type_str = p[:type].stringify %}

          _raw_{{ p[:name] }} = raw[{{ fname }}]?

          {% if type_str == "Int32" %}
            {% if p[:optional] %}
              if _s = _raw_{{ p[:name] }}
                if _n = _s.to_i32?
                  _coerced_{{ p[:name] }} = _n
                else
                  errors << "{{ p[:name] }}: must be an integer"
                  _coerced_{{ p[:name] }} = {{ p[:default] != nil ? p[:default] : 0 }}
                end
              else
                _coerced_{{ p[:name] }} = {{ p[:default] != nil ? p[:default] : 0 }}
              end
            {% else %}
              if _n = _raw_{{ p[:name] }}.not_nil!.to_i32?
                _coerced_{{ p[:name] }} = _n
              else
                errors << "{{ p[:name] }}: must be an integer"
                _coerced_{{ p[:name] }} = 0
              end
            {% end %}
          {% else %}
            {% if p[:optional] %}
              _coerced_{{ p[:name] }} = _raw_{{ p[:name] }}
            {% else %}
              _coerced_{{ p[:name] }} = _raw_{{ p[:name] }}.not_nil!
            {% end %}
          {% end %}

          {% if p[:regexp] %}
            if _check = _raw_{{ p[:name] }}
              errors << "{{ p[:name] }}: does not match required format" unless {{ p[:regexp] }}.match(_check)
            end
          {% end %}

          {% if p[:values] %}
            if _raw_{{ p[:name] }}
              unless ({{ p[:values] }}).includes?(_coerced_{{ p[:name] }})
                errors << "{{ p[:name] }}: value out of allowed range"
              end
            end
          {% end %}

          {% if p[:length] %}
            if _raw_{{ p[:name] }}
              errors << "{{ p[:name] }}: length out of range" unless ({{ p[:length] }}).includes?(_coerced_{{ p[:name] }}.to_s.size)
            end
          {% end %}
        {% end %}

        raise Pika::ValidationError.new(errors) unless errors.empty?

        DeclaredParams.new(
          {% for p in params_list %}
            {{ p[:name] }}: _coerced_{{ p[:name] }},
          {% end %}
        )
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Test subject
# ---------------------------------------------------------------------------

class RegistrationEndpoint
  include Pika::Params

  params do
    requires email : String, regexp: /@/
    requires name : String, length: 1..100
    optional age : Int32 = 0, values: 13..120
    optional bio : String?
  end
end

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

puts "PoC 1: Params DSL Macro"
puts "-" * 40

puts "✓ DeclaredParams struct generated"

# 1. Valid input accepted
valid = RegistrationEndpoint.validate!({
  "email" => "alice@example.com",
  "name"  => "Alice",
  "age"   => "25",
})
raise "email wrong" unless valid.email == "alice@example.com"
raise "name wrong"  unless valid.name == "Alice"
raise "age wrong"   unless valid.age == 25
puts "✓ Valid input accepted and coerced correctly"

# 2. Invalid email format rejected
begin
  RegistrationEndpoint.validate!({"name" => "Bob", "email" => "nope"})
  raise "Should have failed"
rescue e : Pika::ValidationError
  puts "✓ Invalid email format caught: #{e.field_errors}"
end

# 3. Missing required param rejected
begin
  RegistrationEndpoint.validate!({"email" => "alice@example.com"})
  raise "Should have failed"
rescue e : Pika::ValidationError
  puts "✓ Missing required param caught: #{e.field_errors}"
end

# 4. Values constraint (age out of range)
begin
  RegistrationEndpoint.validate!({
    "email" => "bob@example.com",
    "name"  => "Bob",
    "age"   => "200",
  })
  raise "Should have failed"
rescue e : Pika::ValidationError
  puts "✓ Values constraint enforced: #{e.field_errors}"
end

# 5. Optional with default — omitting age gives 0
defaults = RegistrationEndpoint.validate!({
  "email" => "carol@example.com",
  "name"  => "Carol",
})
raise "default age wrong" unless defaults.age == 0
puts "✓ Optional default applied when param absent"

# 6. Optional nilable — bio absent gives nil
raise "bio should be nil" unless defaults.bio.nil?
puts "✓ Optional nilable field is nil when absent"

puts
puts "All assertions passed."
