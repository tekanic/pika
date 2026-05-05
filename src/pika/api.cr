require "http/server"
require "json"
require "./version"
require "./error"
require "./router"
require "./params"
require "./openapi"
require "./entity"
require "./docs"

module Pika
  class API
    # ---------------------------------------------------------------------------
    # Class-level state
    # ---------------------------------------------------------------------------

    @@router           = Pika::Router.new
    @@openapi_routes   = [] of Pika::OpenAPI::RouteSpec
    @@_pika_version    = ""
    @@_pika_path_stack = [] of String
    @@_pika_info_title       = ""
    @@_pika_info_version     = "1.0.0"
    @@_pika_info_description = ""
    @@_pika_before_hooks = [] of Proc(HTTP::Server::Context, Nil)
    @@_pika_after_hooks  = [] of Proc(HTTP::Server::Context, Nil)

    # Pluggable error formatters — default to RFC 7807.
    @@_pika_fmt_validation : Proc(HTTP::Server::Context, Pika::ValidationError, String) =
      ->(env : HTTP::Server::Context, e : Pika::ValidationError) {
        Pika::ErrorFormatter::RFC7807.format_validation(env, e)
      }
    @@_pika_fmt_error : Proc(HTTP::Server::Context, Pika::Error, String) =
      ->(env : HTTP::Server::Context, e : Pika::Error) {
        Pika::ErrorFormatter::RFC7807.format_error(env, e)
      }

    def self.router          : Pika::Router;                    @@router;          end
    def self.openapi_routes  : Array(Pika::OpenAPI::RouteSpec); @@openapi_routes;  end
    def self.openapi         : String;                          Pika::OpenAPI.emit_paths(@@openapi_routes); end

    def self.openapi_doc : String
      Pika::OpenAPI.emit_doc(
        @@openapi_routes,
        title:       @@_pika_info_title.empty? ? name : @@_pika_info_title,
        version:     @@_pika_info_version,
        description: @@_pika_info_description,
      )
    end

    # present — serialize an object or collection through an Entity class.
    # Call from inside a handler block: present user, using: UserEntity
    def self.present(obj, using entity_class, **opts) : String
      entity_class.represent(obj, **opts)
    end

    # ---------------------------------------------------------------------------
    # version — sets a path prefix for the entire API
    #
    #   version "v1", using: :path
    # ---------------------------------------------------------------------------
    macro version(v, **options)
      @@_pika_version = {{ v }}
    end

    # ---------------------------------------------------------------------------
    # info — set API metadata used in the OpenAPI document
    #
    #   info title: "My API", version: "2.0.0", description: "..."
    # ---------------------------------------------------------------------------
    macro info(**options)
      {% for k, v in options %}
        {% if k.id == "title" %}            @@_pika_info_title       = {{ v }}
        {% elsif k.id == "version" %}       @@_pika_info_version     = {{ v }}
        {% elsif k.id == "description" %}   @@_pika_info_description = {{ v }}
        {% end %}
      {% end %}
    end

    # ---------------------------------------------------------------------------
    # docs — mount Scalar UI and OpenAPI JSON endpoint
    #
    #   docs at: "/docs"   # GET /docs → Scalar HTML
    #                      # GET /docs/openapi.json → OpenAPI 3.1
    # ---------------------------------------------------------------------------
    macro docs(at = "/docs")
      @@router.add("GET", {{ at }}) do |_pika_env|
        _pika_env.response.content_type = "text/html"
        Pika::Docs.scalar_html({{ at + "/openapi.json" }})
      end
      @@router.add("GET", {{ at + "/openapi.json" }}) do |_pika_env|
        _pika_env.response.content_type = "application/json"
        {{ @type }}.openapi_doc
      end
    end

    # ---------------------------------------------------------------------------
    # namespace — groups routes under a common path segment
    #
    #   namespace :admin do
    #     resource :users do ... end
    #   end
    # ---------------------------------------------------------------------------
    macro namespace(name, &block)
      @@_pika_path_stack << {{ name.id.stringify }}
      {{ block.body }}
      @@_pika_path_stack.pop
    end

    # ---------------------------------------------------------------------------
    # before / after hooks — run around every route handler in this class
    #
    #   before do
    #     raise Pika::UnauthorizedError.new unless env.request.headers["X-Token"]?
    #   end
    # ---------------------------------------------------------------------------
    macro before(&block)
      @@_pika_before_hooks << ->(env : HTTP::Server::Context) {
        {{ block.body }}
        nil
      }
    end

    macro after(&block)
      @@_pika_after_hooks << ->(env : HTTP::Server::Context) {
        {{ block.body }}
        nil
      }
    end

    # ---------------------------------------------------------------------------
    # helpers — define class-level helper methods accessible inside handlers
    #
    #   helpers do
    #     def self.current_user(env)
    #       env.request.headers["X-User-Id"]?
    #     end
    #   end
    # ---------------------------------------------------------------------------
    macro helpers(&block)
      {{ block.body }}
    end

    # ---------------------------------------------------------------------------
    # error_formatter — select the active error serialization format
    #
    #   error_formatter :rfc7807   # default — application/problem+json
    #   error_formatter :grape     # {"error": "message"}
    #   error_formatter :jsonapi   # {"errors": [...]}
    # ---------------------------------------------------------------------------
    macro error_formatter(fmt)
      @@_pika_fmt_validation : Proc(HTTP::Server::Context, Pika::ValidationError, String) =
        ->(env : HTTP::Server::Context, e : Pika::ValidationError) {
          {% if fmt.id == "grape" %}
            Pika::ErrorFormatter::Grape.format_validation(env, e)
          {% elsif fmt.id == "jsonapi" %}
            Pika::ErrorFormatter::JSONAPI.format_validation(env, e)
          {% else %}
            Pika::ErrorFormatter::RFC7807.format_validation(env, e)
          {% end %}
        }
      @@_pika_fmt_error : Proc(HTTP::Server::Context, Pika::Error, String) =
        ->(env : HTTP::Server::Context, e : Pika::Error) {
          {% if fmt.id == "grape" %}
            Pika::ErrorFormatter::Grape.format_error(env, e)
          {% elsif fmt.id == "jsonapi" %}
            Pika::ErrorFormatter::JSONAPI.format_error(env, e)
          {% else %}
            Pika::ErrorFormatter::RFC7807.format_error(env, e)
          {% end %}
        }
    end

    # ---------------------------------------------------------------------------
    # mount — compose another Pika::API's routes into this one
    #
    #   mount AdminAPI          # copies /admin/... routes verbatim
    #
    # The current version + namespace prefix is applied to all mounted paths.
    # ---------------------------------------------------------------------------
    macro mount(api_class)
      _pika_mount_prefix = (@@_pika_version.empty? ? "" : "/#{@@_pika_version}") +
                           (@@_pika_path_stack.empty? ? "" : "/" + @@_pika_path_stack.join("/"))
      {{ api_class }}.router.each_route do |_m_method, _m_path, _m_handler|
        @@router.add(_m_method, _pika_mount_prefix + _m_path, &_m_handler)
      end
      @@openapi_routes.concat({{ api_class }}.openapi_routes)
    end

    # ---------------------------------------------------------------------------
    # resource macro
    #
    # The core DSL macro. Parses its block body as an AST to accumulate
    # desc / params / verb triples, then generates:
    #   1. A typed DeclaredParams struct per route.
    #   2. A validate! class method with full constraint enforcement.
    #   3. A Pika::Router#add registration (path computed at class-init time).
    #   4. A Pika::OpenAPI::RouteSpec entry.
    #
    # Supports nested route_param blocks one level deep:
    #
    #   resource :users do
    #     get do ... end           # GET /users
    #     post do ... end          # POST /users
    #
    #     route_param :id do
    #       get do ... end         # GET /users/:id
    #       patch do ... end       # PATCH /users/:id
    #       delete do ... end      # DELETE /users/:id
    #     end
    #   end
    #
    # Params blocks support mutually_exclusive / at_least_one_of / exactly_one_of:
    #
    #   params do
    #     optional email : String?
    #     optional phone : String?
    #     mutually_exclusive :email, :phone
    #   end
    # ---------------------------------------------------------------------------
    macro resource(name, &block)
      {% resource_name   = name.id.stringify %}
      {% resource_prefix = resource_name.gsub(/[^a-zA-Z0-9]/, "_") %}
      {% route_list      = [] of Nil %}
      {% pending_desc    = "" %}
      {% pending_body    = [] of Nil %}
      {% pending_mutex   = [] of Nil %}

      {% if block.body.is_a?(Expressions) %}
        {% stmts = block.body.expressions %}
      {% else %}
        {% stmts = [block.body] %}
      {% end %}

      {% for expr in stmts %}
        {% if expr.is_a?(Call) %}

          # --- desc -----------------------------------------------------------
          {% if expr.name == "desc" %}
            {% pending_desc = expr.args[0] %}

          # --- params ---------------------------------------------------------
          {% elsif expr.name == "params" %}
            {% pending_body  = [] of Nil %}
            {% pending_mutex = [] of Nil %}
            {% pb = expr.block.body %}
            {% if pb.is_a?(Expressions) %}{% pexprs = pb.expressions %}{% else %}{% pexprs = [pb] %}{% end %}
            {% for pexpr in pexprs %}
              {% if pexpr.is_a?(Call) %}
                {% if pexpr.name == "requires" || pexpr.name == "optional" %}
                  {% decl = pexpr.args[0] %}
                  {% ts = decl.type.stringify %}
                  {% if ts == "Int32" || ts == "Int64" || ts == "Int32?" || ts == "Int64?" %}{% oa = "integer" %}
                  {% elsif ts == "Float32" || ts == "Float64" || ts == "Float64?" %}{% oa = "number" %}
                  {% elsif ts == "Bool" || ts == "Bool?" %}{% oa = "boolean" %}
                  {% else %}{% oa = "string" %}{% end %}
                  {% rg = nil %}{% va = nil %}{% le = nil %}
                  {% if pexpr.named_args %}
                    {% for na in pexpr.named_args %}
                      {% if na.name == "regexp" %}{% rg = na.value %}{% end %}
                      {% if na.name == "values" %}{% va = na.value %}{% end %}
                      {% if na.name == "length" %}{% le = na.value %}{% end %}
                    {% end %}
                  {% end %}
                  {% pending_body << {name: decl.var, oa_type: oa, required: pexpr.name == "requires",
                                      opt: pexpr.name == "optional", type: decl.type, default: decl.value,
                                      has_default: !decl.value.is_a?(Nop),
                                      regexp: rg, values: va, length: le} %}
                {% elsif pexpr.name == "mutually_exclusive" || pexpr.name == "at_least_one_of" || pexpr.name == "exactly_one_of" %}
                  {% mxf = [] of Nil %}
                  {% for arg in pexpr.args %}{% mxf << arg.id.stringify %}{% end %}
                  {% pending_mutex << {kind: pexpr.name.stringify, fields: mxf} %}
                {% end %}
              {% end %}
            {% end %}

          # --- params_from --------------------------------------------------------
          # Derives a params block from a model's PIKA_COLUMNS constant.
          # The constant is a NamedTuple array generated by Pika::Clear::Model
          # (or defined manually). Nilable columns become optional params.
          {% elsif expr.name == "params_from" %}
            {% pending_body  = [] of Nil %}
            {% pending_mutex = [] of Nil %}
            {% pf_model = expr.args[0].resolve %}
            {% only_list   = [] of Nil %}
            {% except_list = [] of Nil %}
            {% if expr.named_args %}
              {% for na in expr.named_args %}
                {% if na.name == "only"   %}{% only_list   = na.value.map { |s| s.id.stringify } %}{% end %}
                {% if na.name == "except" %}{% except_list = na.value.map { |s| s.id.stringify } %}{% end %}
              {% end %}
            {% end %}
            {% cols = pf_model.constant("PIKA_COLUMNS") %}
            {% if cols %}
              {% for col in cols %}
                {% include_field = only_list.empty? %}
                {% for n in only_list   %}{% include_field = true  if n == col[:name] %}{% end %}
                {% for n in except_list %}{% include_field = false if n == col[:name] %}{% end %}
                {% if include_field %}
                  {% nl = col[:nilable] %}
                  {% pending_body << {name: col[:name].id, oa_type: col[:oa_kind], required: !nl,
                                      opt: nl, type: col[:type_str].id, default: nil,
                                      has_default: nl,
                                      regexp: nil, values: nil, length: nil} %}
                {% end %}
              {% end %}
            {% end %}

          # --- route_param ----------------------------------------------------
          {% elsif expr.name == "route_param" %}
            {% rp_name        = expr.args[0].id.stringify %}
            {% rp_pending_desc  = "" %}
            {% rp_pending_body  = [] of Nil %}
            {% rp_pending_mutex = [] of Nil %}
            {% rp_pb = expr.block.body %}
            {% if rp_pb.is_a?(Expressions) %}{% rp_stmts = rp_pb.expressions %}{% else %}{% rp_stmts = [rp_pb] %}{% end %}

            {% for rp_expr in rp_stmts %}
              {% if rp_expr.is_a?(Call) %}
                {% if rp_expr.name == "desc" %}
                  {% rp_pending_desc = rp_expr.args[0] %}

                {% elsif rp_expr.name == "params" %}
                  {% rp_pending_body  = [] of Nil %}
                  {% rp_pending_mutex = [] of Nil %}
                  {% rp_pb2 = rp_expr.block.body %}
                  {% if rp_pb2.is_a?(Expressions) %}{% rp_pexprs = rp_pb2.expressions %}{% else %}{% rp_pexprs = [rp_pb2] %}{% end %}
                  {% for rp_pexpr in rp_pexprs %}
                    {% if rp_pexpr.is_a?(Call) %}
                      {% if rp_pexpr.name == "requires" || rp_pexpr.name == "optional" %}
                        {% rp_decl = rp_pexpr.args[0] %}
                        {% rp_ts = rp_decl.type.stringify %}
                        {% if rp_ts == "Int32" || rp_ts == "Int64" || rp_ts == "Int32?" || rp_ts == "Int64?" %}{% rp_oa = "integer" %}
                        {% elsif rp_ts == "Float32" || rp_ts == "Float64" || rp_ts == "Float64?" %}{% rp_oa = "number" %}
                        {% elsif rp_ts == "Bool" || rp_ts == "Bool?" %}{% rp_oa = "boolean" %}
                        {% else %}{% rp_oa = "string" %}{% end %}
                        {% rp_rg = nil %}{% rp_va = nil %}{% rp_le = nil %}
                        {% if rp_pexpr.named_args %}
                          {% for na in rp_pexpr.named_args %}
                            {% if na.name == "regexp" %}{% rp_rg = na.value %}{% end %}
                            {% if na.name == "values" %}{% rp_va = na.value %}{% end %}
                            {% if na.name == "length" %}{% rp_le = na.value %}{% end %}
                          {% end %}
                        {% end %}
                        {% rp_pending_body << {name: rp_decl.var, oa_type: rp_oa,
                                               required: rp_pexpr.name == "requires",
                                               opt: rp_pexpr.name == "optional",
                                               type: rp_decl.type, default: rp_decl.value,
                                               has_default: !rp_decl.value.is_a?(Nop),
                                               regexp: rp_rg, values: rp_va, length: rp_le} %}
                      {% elsif rp_pexpr.name == "mutually_exclusive" || rp_pexpr.name == "at_least_one_of" || rp_pexpr.name == "exactly_one_of" %}
                        {% rp_mxf = [] of Nil %}
                        {% for arg in rp_pexpr.args %}{% rp_mxf << arg.id.stringify %}{% end %}
                        {% rp_pending_mutex << {kind: rp_pexpr.name.stringify, fields: rp_mxf} %}
                      {% end %}
                    {% end %}
                  {% end %}

                {% elsif rp_expr.name == "get" || rp_expr.name == "post" || rp_expr.name == "put" || rp_expr.name == "patch" || rp_expr.name == "delete" || rp_expr.name == "head" %}
                  {% rp_verb = rp_expr.name.stringify %}
                  {% rp_sn   = "PikaP_#{resource_prefix.id}_#{rp_name.id}_#{rp_verb.id}" %}
                  {% route_list << {verb: rp_verb, struct_name: rp_sn,
                                    summary: rp_pending_desc, body_params: rp_pending_body,
                                    mutex_groups: rp_pending_mutex, path_suffix: ":" + rp_name,
                                    rp_name: rp_name, handler: rp_expr.block} %}
                  {% rp_pending_desc  = "" %}
                  {% rp_pending_body  = [] of Nil %}
                  {% rp_pending_mutex = [] of Nil %}
                {% end %}
              {% end %}
            {% end %}

          # --- HTTP verbs -----------------------------------------------------
          {% elsif expr.name == "get" || expr.name == "post" || expr.name == "put" || expr.name == "patch" || expr.name == "delete" || expr.name == "head" %}
            {% verb = expr.name.stringify %}
            {% sn   = "PikaP_#{resource_prefix.id}_#{verb.id}" %}
            {% route_list << {verb: verb, struct_name: sn,
                              summary: pending_desc, body_params: pending_body,
                              mutex_groups: pending_mutex, path_suffix: "",
                              rp_name: "", handler: expr.block} %}
            {% pending_desc  = "" %}
            {% pending_body  = [] of Nil %}
            {% pending_mutex = [] of Nil %}
          {% end %}

        {% end %}
      {% end %}

      # =========================================================================
      # Code generation — one pass per collected route
      # =========================================================================

      {% for r in route_list %}
        {% sn = r[:struct_name] %}

        # --- DeclaredParams struct -------------------------------------------
        struct {{ sn.id }}
          {% unless r[:rp_name].empty? %}
            property {{ r[:rp_name].id }} : String
          {% end %}
          {% for p in r[:body_params] %}
            {% if p[:opt] && p[:has_default] %}
              property {{ p[:name] }} : {{ p[:type] }} = {{ p[:default] }}
            {% else %}
              property {{ p[:name] }} : {{ p[:type] }}
            {% end %}
          {% end %}
          def initialize(
            {% unless r[:rp_name].empty? %}@{{ r[:rp_name].id }} : String,{% end %}
            {% for p in r[:body_params] %}@{{ p[:name] }} : {{ p[:type] }},{% end %}
          ); end
        end

        # --- validate! method ------------------------------------------------
        def self.validate_{{ sn.downcase.id }}!(raw : Hash(String, String)) : {{ sn.id }}
          _errors = [] of {field: String, message: String}

          {% for p in r[:body_params] %}
            _raw_{{ p[:name] }} = raw[{{ p[:name].stringify }}]?

            # String? stringifies as "String | Nil" (no parens) in Crystal macros
            {% ts      = p[:type].stringify %}
            {% nilable = ts.includes?("Nil") || ts.ends_with?("?") %}

            {% if ts.includes?("String") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}""{% end %}
              if _v = _raw_{{ p[:name] }}
                _val_{{ p[:name] }} = _v
                {% unless p[:regexp].is_a?(NilLiteral) %}
                  _errors << {field: {{ p[:name].stringify }}, message: "must match #{{{ p[:regexp] }}.source}"} unless _val_{{ p[:name] }}.matches?({{ p[:regexp] }})
                {% end %}
                {% unless p[:length].is_a?(NilLiteral) %}
                  _errors << {field: {{ p[:name].stringify }}, message: "length must be in #{{{ p[:length] }}}"} unless ({{ p[:length] }}).includes?(_val_{{ p[:name] }}.size)
                {% end %}
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.includes?("Int32") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% elsif p[:has_default] %}{{ p[:default] }}{% else %}0{% end %}
              if _v = _raw_{{ p[:name] }}
                _parsed_{{ p[:name] }} = _v.to_i32?
                if _parsed_{{ p[:name] }}
                  _val_{{ p[:name] }} = _parsed_{{ p[:name] }}
                  {% unless p[:values].is_a?(NilLiteral) %}
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

            {% elsif ts.includes?("Int64") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% elsif p[:has_default] %}{{ p[:default] }}.to_i64{% else %}0_i64{% end %}
              if _v = _raw_{{ p[:name] }}
                _parsed_{{ p[:name] }} = _v.to_i64?
                if _parsed_{{ p[:name] }}
                  _val_{{ p[:name] }} = _parsed_{{ p[:name] }}
                  {% unless p[:values].is_a?(NilLiteral) %}
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
                  {% unless p[:values].is_a?(NilLiteral) %}
                    _errors << {field: {{ p[:name].stringify }}, message: "must be in #{{{ p[:values] }}}"} unless ({{ p[:values] }}).includes?(_val_{{ p[:name] }}.not_nil!)
                  {% end %}
                else
                  _errors << {field: {{ p[:name].stringify }}, message: "must be a number"}
                end
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.includes?("Bool") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% elsif p[:has_default] %}{{ p[:default] }}{% else %}false{% end %}
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

          # Mutex group checks
          {% mx_idx = 0 %}
          {% for mx in r[:mutex_groups] %}
            _mx_count_{{ mx_idx }} = [{% for f in mx[:fields] %}_raw_{{ f.id }}, {% end %}].compact.size
            {% if mx[:kind] == "mutually_exclusive" %}
              _errors << {field: "base", message: "{{ mx[:fields].join(", ").id }} are mutually exclusive"} if _mx_count_{{ mx_idx }} > 1
            {% elsif mx[:kind] == "at_least_one_of" %}
              _errors << {field: "base", message: "at least one of {{ mx[:fields].join(", ").id }} is required"} if _mx_count_{{ mx_idx }} == 0
            {% elsif mx[:kind] == "exactly_one_of" %}
              _errors << {field: "base", message: "exactly one of {{ mx[:fields].join(", ").id }} is required"} unless _mx_count_{{ mx_idx }} == 1
            {% end %}
            {% mx_idx = mx_idx + 1 %}
          {% end %}

          raise Pika::ValidationError.new(_errors) unless _errors.empty?
          {{ sn.id }}.new(
            {% unless r[:rp_name].empty? %}{{ r[:rp_name].id }}: raw[{{ r[:rp_name] }}]? || "",{% end %}
            {% for p in r[:body_params] %}{{ p[:name] }}: _val_{{ p[:name] }},{% end %}
          )
        end

        # --- Route & OpenAPI registration -----------------------------------
        # Path is computed at class-init time so namespace / version stack values
        # are already correct when this code runs.
        _pika_prefix = (@@_pika_version.empty? ? "" : "/#{@@_pika_version}") + (@@_pika_path_stack.empty? ? "" : "/" + @@_pika_path_stack.join("/"))
        _pika_path   = _pika_prefix + "/#{{{ resource_name }}}" + {{ r[:path_suffix].empty? ? "" : "/" + r[:path_suffix] }}

        @@router.add({{ r[:verb].upcase }}, _pika_path) do |_pika_env|
          begin
            @@_pika_before_hooks.each(&.call(_pika_env))
            _pika_raw = Pika::Params.from_env(_pika_env)
            declared_params = validate_{{ sn.downcase.id }}!(_pika_raw)
            env = _pika_env
            env.response.content_type = "application/json"
            result = ({{ r[:handler].body }})
            @@_pika_after_hooks.each(&.call(_pika_env))
            result ? result.to_s : nil
          rescue e : Pika::ValidationError
            @@_pika_fmt_validation.call(_pika_env, e)
          rescue e : Pika::Error
            @@_pika_fmt_error.call(_pika_env, e)
          end
        end

        @@openapi_routes << Pika::OpenAPI::RouteSpec.new(
          method:  {{ r[:verb] }},
          path:    _pika_path,
          summary: {{ r[:summary] }},
          parameters: [
            {% unless r[:rp_name].empty? %}
              Pika::OpenAPI::ParameterSpec.new(name: {{ r[:rp_name] }}, location: "path", required: true, schema_type: "string"),
            {% end %}
            {% has_body = !r[:body_params].empty? && (r[:verb] == "post" || r[:verb] == "put" || r[:verb] == "patch") %}
            {% unless has_body %}
              {% for p in r[:body_params] %}
                Pika::OpenAPI::ParameterSpec.new(name: {{ p[:name].stringify }}, location: "query", required: {{ !p[:opt] }}, schema_type: {{ p[:oa_type] }}),
              {% end %}
            {% end %}
          ] of Pika::OpenAPI::ParameterSpec,
          {% if has_body %}
            request_body: Pika::OpenAPI::RequestBodySpec.new(
              required_fields: [{% for p in r[:body_params] %}{% if p[:required] %}{name: {{ p[:name].stringify }}, schema_type: {{ p[:oa_type] }}},{% end %}{% end %}] of {name: String, schema_type: String},
              optional_fields: [{% for p in r[:body_params] %}{% unless p[:required] %}{name: {{ p[:name].stringify }}, schema_type: {{ p[:oa_type] }}},{% end %}{% end %}] of {name: String, schema_type: String},
            ),
          {% else %}
            request_body: nil,
          {% end %}
        )
      {% end %}
    end

    # ---------------------------------------------------------------------------
    # Server lifecycle
    # ---------------------------------------------------------------------------

    def self.run(host : String = "0.0.0.0", port : Int32 = 3000, reuse_port : Bool = false)
      server = HTTP::Server.new { |ctx| @@router.call(ctx) }
      address = server.bind_tcp(host, port, reuse_port: reuse_port)
      puts "Pika #{Pika::VERSION} listening on http://#{address}"
      server.listen
    end
  end
end
