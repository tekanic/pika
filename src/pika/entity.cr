require "json"

module Pika
  # Base class for entity presenters. T is the model type being serialized.
  #
  # Usage:
  #   class UserEntity < Pika::Entity(User)
  #     pika_entity do
  #       expose :id
  #       expose :name
  #       expose :email, if: :full_view
  #       expose(:display_name) { |u| "#{u.first_name} #{u.last_name}" }
  #     end
  #   end
  #
  #   # In a handler:
  #   present user, using: UserEntity
  #   present user, using: UserEntity, full_view: true
  #   present users, using: UserEntity

  abstract class Entity(T)
    # pika_entity — parses all expose calls in its block, generates represent methods.
    #
    # Supported options on expose:
    #   if: :flag_name  — include field only when that keyword arg is truthy in represent call
    #   if: nil (omitted) — always include
    #
    # Supported block form:
    #   expose(:key) { |obj| obj.some_computed_value }
    macro pika_entity(&block)
      {% expose_list = [] of Nil %}

      {% if block.body.is_a?(Expressions) %}
        {% stmts = block.body.expressions %}
      {% else %}
        {% stmts = [block.body] %}
      {% end %}

      {% for stmt in stmts %}
        {% if stmt.is_a?(Call) && stmt.name == "expose" %}
          {% field = stmt.args[0].id.stringify %}
          {% key   = field %}
          {% cond  = nil %}
          {% blk   = stmt.block %}

          {% if stmt.named_args %}
            {% for na in stmt.named_args %}
              {% if na.name == "key" %}{% key = na.value.id.stringify %}{% end %}
              {% if na.name == "if"  %}{% cond = na.value %}{% end %}
            {% end %}
          {% end %}

          {% expose_list << {field: field, key: key, cond: cond, blk: blk} %}
        {% end %}
      {% end %}

      # Generate represent(single object) class method
      def self.represent(obj : T, **opts) : String
        String.build do |_io|
          _io << "{"
          _first = true

          {% for e in expose_list %}
            _show_{{ e[:field].id }} = {% if e[:cond].is_a?(NilLiteral) %}
              true
            {% elsif e[:cond].is_a?(SymbolLiteral) %}
              !!opts[{{ e[:cond] }}]?
            {% else %}
              ({{ e[:cond] }}).call(obj, opts)
            {% end %}

            if _show_{{ e[:field].id }}
              _io << "," unless _first
              _first = false
              _io << {{ "\"#{e[:key].id}\":" }}
              {% if e[:blk] %}
                {% if !e[:blk].args.empty? %}
                  {{ e[:blk].args[0].id }} = obj
                {% end %}
                _io << ({{ e[:blk].body }}).to_json
              {% else %}
                _io << obj.{{ e[:field].id }}.to_json
              {% end %}
            end
          {% end %}

          _io << "}"
        end
      end

      # Generate represent(collection) class method
      def self.represent(collection : Enumerable(T), **opts) : String
        String.build do |_io|
          _io << "["
          _first = true
          collection.each do |_item|
            _io << "," unless _first
            _first = false
            _io << represent(_item, **opts)
          end
          _io << "]"
        end
      end
    end
  end
end
