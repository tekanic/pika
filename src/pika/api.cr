require "http/server"
require "json"
require "uuid"
require "./version"
require "./versioning"
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

    @@router                  = Pika::Router.new
    @@openapi_routes          = [] of Pika::OpenAPI::RouteSpec
    @@openapi_schemas         = {} of String => JSON::Any
    @@_pika_version           = ""
    @@_pika_version_strategy  = Pika::VersionStrategy::Path
    @@_pika_version_vendor    = ""
    @@_pika_path_stack        = [] of String
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
    def self.openapi_schemas : Hash(String, JSON::Any);         @@openapi_schemas; end
    def self.openapi         : String;                          Pika::OpenAPI.emit_paths(@@openapi_routes); end

    def self.openapi_doc : String
      Pika::OpenAPI.emit_doc(
        @@openapi_routes,
        title:       @@_pika_info_title.empty? ? name : @@_pika_info_title,
        version:     @@_pika_info_version,
        description: @@_pika_info_description,
        schemas:     @@openapi_schemas,
      )
    end

    # present — serialize an object or collection through an Entity class.
    # Call from inside a handler block: present user, using: UserEntity
    def self.present(obj, using entity_class, **opts) : String
      entity_class.represent(obj, **opts)
    end

    # ---------------------------------------------------------------------------
    # status / header — set the response status code and headers from a handler.
    #
    # These are macros, not methods: they expand to operations on the `env`
    # local that is in scope inside every generated handler (and before/after
    # hook) block. That keeps them fully lexical — no shared request state — so
    # they are correct under multi-threading and concurrent fibers.
    #
    #   post do
    #     user = create_user(declared_params)
    #     status 201
    #     header "Location", "/v1/users/#{user.id}"
    #     present user, using: UserEntity
    #   end
    # ---------------------------------------------------------------------------
    macro status(code)
      env.response.status_code = ({{ code }})
    end

    macro header(name, value)
      env.response.headers[{{ name }}] = ({{ value }})
    end

    # request_id — the per-request ID inside a handler (empty if observability
    # is not enabled). The router sets it on both request and response headers.
    macro request_id
      (env.request.headers["X-Request-Id"]? || "")
    end

    # ---------------------------------------------------------------------------
    # version — declare the API version and how clients communicate it.
    #
    #   version "v1"                                  # path prefix (default)
    #   version "v1", using: :path                    # /v1/resource
    #   version "v1", using: :header                  # X-Api-Version: v1
    #   version "v1", using: :accept, vendor: "myapi" # Accept: application/vnd.myapi.v1+json
    # ---------------------------------------------------------------------------
    macro version(v, **options)
      @@_pika_version = {{ v }}
      {% using_val = options[:using] ? options[:using].id.stringify : "path" %}
      {% if using_val == "header" %}
        @@_pika_version_strategy = Pika::VersionStrategy::Header
      {% elsif using_val == "accept" %}
        @@_pika_version_strategy = Pika::VersionStrategy::Accept
      {% else %}
        @@_pika_version_strategy = Pika::VersionStrategy::Path
      {% end %}
      {% if options[:vendor] %}
        @@_pika_version_vendor = {{ options[:vendor] }}
      {% end %}
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
    # observability — enable per-request structured logging + request IDs.
    #
    #   observability                 # JSON access log line per request
    #   observability log: false      # request IDs only, no log line
    # ---------------------------------------------------------------------------
    macro observability(log = true)
      (@@router.observability ||= Pika::Observability.new).log = {{ log }}
    end

    # instrument — register a metrics/tracing callback run after every request.
    # This is the documented extension point other tooling attaches to.
    #
    #   instrument do |info|
    #     Metrics.timing(info.path, info.duration)
    #   end
    # ---------------------------------------------------------------------------
    macro instrument(&block)
      (@@router.observability ||= Pika::Observability.new(log: false)).instrument =
        ->(_pika_info : Pika::RequestInfo) {
          {% if block.args.size > 0 %}{{ block.args[0].id }} = _pika_info{% end %}
          {{ block.body }}
          nil
        }
    end

    # ---------------------------------------------------------------------------
    # cors — enable CORS for this API. Preflight (OPTIONS) is handled
    # automatically by the router; actual responses get the allow headers.
    #
    #   cors origins: ["https://app.example.com"],
    #        methods: ["GET", "POST"],
    #        headers: ["Content-Type", "Authorization"],
    #        credentials: true
    # ---------------------------------------------------------------------------
    macro cors(origins = ["*"],
               methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
               headers = ["Content-Type", "Authorization"],
               credentials = false,
               max_age = 600)
      @@router.cors = Pika::CORS.new(
        origins:     {{ origins }},
        methods:     {{ methods }},
        headers:     {{ headers }},
        credentials: {{ credentials }},
        max_age:     {{ max_age }},
      )
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
      _pika_mount_prefix = (
        @@_pika_version_strategy == Pika::VersionStrategy::Path ?
          (@@_pika_version.empty? ? "" : "/#{@@_pika_version}") : ""
      ) + (@@_pika_path_stack.empty? ? "" : "/" + @@_pika_path_stack.join("/"))
      {{ api_class }}.router.each_route do |_m_method, _m_path, _m_ver, _m_strat, _m_vendor, _m_handler|
        @@router.add(_m_method, _pika_mount_prefix + _m_path, _m_ver, _m_strat, _m_vendor, &_m_handler)
      end
      @@openapi_routes.concat({{ api_class }}.openapi_routes)
      {{ api_class }}.openapi_schemas.each { |_k, _v| @@openapi_schemas[_k] = _v }
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
      {% pending_returns = [] of Nil %}

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

          # --- returns --------------------------------------------------------
          # returns 201, UserEntity   # documents a 201 response with the entity schema
          # returns 422               # documents a 422 with the generic error schema
          {% elsif expr.name == "returns" %}
            {% pending_returns << {status: expr.args[0], entity: (expr.args.size > 1 ? expr.args[1] : nil)} %}

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
                  {% if ts.starts_with?("Array") %}{% oa = "array" %}
                  {% elsif ts.includes?("Int32") || ts.includes?("Int64") %}{% oa = "integer" %}
                  {% elsif ts.includes?("Float32") || ts.includes?("Float64") %}{% oa = "number" %}
                  {% elsif ts.includes?("Bool") %}{% oa = "boolean" %}
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
            {% rp_pending_returns = [] of Nil %}
            {% rp_pb = expr.block.body %}
            {% if rp_pb.is_a?(Expressions) %}{% rp_stmts = rp_pb.expressions %}{% else %}{% rp_stmts = [rp_pb] %}{% end %}

            {% for rp_expr in rp_stmts %}
              {% if rp_expr.is_a?(Call) %}
                {% if rp_expr.name == "desc" %}
                  {% rp_pending_desc = rp_expr.args[0] %}

                {% elsif rp_expr.name == "returns" %}
                  {% rp_pending_returns << {status: rp_expr.args[0], entity: (rp_expr.args.size > 1 ? rp_expr.args[1] : nil)} %}

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
                        {% if rp_ts.starts_with?("Array") %}{% rp_oa = "array" %}
                        {% elsif rp_ts.includes?("Int32") || rp_ts.includes?("Int64") %}{% rp_oa = "integer" %}
                        {% elsif rp_ts.includes?("Float32") || rp_ts.includes?("Float64") %}{% rp_oa = "number" %}
                        {% elsif rp_ts.includes?("Bool") %}{% rp_oa = "boolean" %}
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
                                    rp_name: rp_name, handler: rp_expr.block, returns: rp_pending_returns} %}
                  {% rp_pending_desc    = "" %}
                  {% rp_pending_body    = [] of Nil %}
                  {% rp_pending_mutex   = [] of Nil %}
                  {% rp_pending_returns = [] of Nil %}
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
                              rp_name: "", handler: expr.block, returns: pending_returns} %}
            {% pending_desc    = "" %}
            {% pending_body    = [] of Nil %}
            {% pending_mutex   = [] of Nil %}
            {% pending_returns = [] of Nil %}
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
        def self.validate_{{ sn.downcase.id }}!(raw : Hash(String, String),
                                                files : Hash(String, Pika::UploadedFile) = {} of String => Pika::UploadedFile) : {{ sn.id }}
          _errors = [] of {field: String, message: String}

          {% for p in r[:body_params] %}
            _raw_{{ p[:name] }} = raw[{{ p[:name].stringify }}]?

            # String? stringifies as "String | Nil" (no parens) in Crystal macros
            {% ts      = p[:type].stringify %}
            {% nilable = ts.includes?("Nil") || ts.ends_with?("?") %}

            {% if ts.includes?("UploadedFile") %}
              # File params come from multipart/form-data, not the raw text hash.
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}Pika::UploadedFile.empty{% end %}
              if _f = files[{{ p[:name].stringify }}]?
                _val_{{ p[:name] }} = _f
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.starts_with?("Array") %}
              # Array params arrive as a JSON array (typically in a JSON body).
              {% scalar_elem = ts.includes?("String") || ts.includes?("Int32") || ts.includes?("Int64") || ts.includes?("Float64") || ts.includes?("Bool") %}
              {% arr_base = ts.gsub(/ \| (?:::)?Nil/, "").strip %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}{{ arr_base.id }}.new{% end %}
              if _v = _raw_{{ p[:name] }}
                {% if scalar_elem %}
                  begin
                    _arr_{{ p[:name] }} = JSON.parse(_v).as_a?
                    if _arr_{{ p[:name] }}
                      _val_{{ p[:name] }} = _arr_{{ p[:name] }}.map do |_e|
                        {% if ts.includes?("Int64") %} _e.as_i64
                        {% elsif ts.includes?("Int32") %} _e.as_i
                        {% elsif ts.includes?("Float64") %} _e.as_f
                        {% elsif ts.includes?("Bool") %} _e.as_bool
                        {% else %} _e.as_s {% end %}
                      end
                    else
                      _errors << {field: {{ p[:name].stringify }}, message: "must be an array"}
                    end
                  rescue
                    _errors << {field: {{ p[:name].stringify }}, message: "must be an array of the correct element type"}
                  end
                {% else %}
                  # Array of nested objects — deserialize the whole array via JSON.
                  begin
                    _val_{{ p[:name] }} = {{ arr_base.id }}.from_json(_v)
                  rescue
                    _errors << {field: {{ p[:name].stringify }}, message: "must be an array of valid objects"}
                  end
                {% end %}
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.includes?("UUID") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}UUID.empty{% end %}
              if _v = _raw_{{ p[:name] }}
                begin
                  _val_{{ p[:name] }} = UUID.new(_v)
                rescue
                  _errors << {field: {{ p[:name].stringify }}, message: "must be a valid UUID"}
                end
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.includes?("Time") %}
              _val_{{ p[:name] }} : {{ p[:type] }} = {% if nilable %}nil{% else %}Time::UNIX_EPOCH{% end %}
              if _v = _raw_{{ p[:name] }}
                begin
                  _val_{{ p[:name] }} = Time.parse_rfc3339(_v)
                rescue
                  _errors << {field: {{ p[:name].stringify }}, message: "must be an RFC 3339 timestamp"}
                end
              else
                {% unless p[:opt] %}
                  _errors << {field: {{ p[:name].stringify }}, message: "is required"}
                {% end %}
              end

            {% elsif ts.includes?("String") %}
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

            {% else %}
              # Nested object param — JSON-deserialized (e.g. a Pika.object type).
              # Held in a nilable temp; the struct receives `.not_nil!` when the
              # field itself is non-nilable (we raise before constructing if absent).
              {% obj_base = ts.gsub(/ \| (?:::)?Nil/, "").strip %}
              _val_{{ p[:name] }} = nil.as({{ obj_base.id }}?)
              if _v = _raw_{{ p[:name] }}
                begin
                  _val_{{ p[:name] }} = {{ obj_base.id }}.from_json(_v)
                rescue
                  _errors << {field: {{ p[:name].stringify }}, message: "must be a valid object"}
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
            {% for p in r[:body_params] %}
              {% cpt = p[:type].stringify %}
              {% c_scalarish = cpt.includes?("String") || cpt.includes?("Int32") || cpt.includes?("Int64") || cpt.includes?("Float64") || cpt.includes?("Bool") || cpt.includes?("UUID") || cpt.includes?("Time") || cpt.includes?("UploadedFile") %}
              {% plain_obj_nonnil = !c_scalarish && !cpt.starts_with?("Array") && !cpt.includes?("Nil") %}
              {{ p[:name] }}: _val_{{ p[:name] }}{% if plain_obj_nonnil %}.not_nil!{% end %},
            {% end %}
          )
        end

        # --- Route & OpenAPI registration -----------------------------------
        # Path is computed at class-init time so namespace / version stack values
        # are already correct when this code runs.
        # For non-path strategies the version is communicated via a header, so
        # no URL prefix is added — the version info travels with the route entry.
        _pika_ver_prefix = @@_pika_version_strategy == Pika::VersionStrategy::Path ?
          (@@_pika_version.empty? ? "" : "/#{@@_pika_version}") : ""
        _pika_prefix = _pika_ver_prefix + (@@_pika_path_stack.empty? ? "" : "/" + @@_pika_path_stack.join("/"))
        _pika_path   = _pika_prefix + "/#{{{ resource_name }}}" + {{ r[:path_suffix].empty? ? "" : "/" + r[:path_suffix] }}

        @@router.add({{ r[:verb].upcase }}, _pika_path,
                     @@_pika_version, @@_pika_version_strategy, @@_pika_version_vendor) do |_pika_env|
          begin
            @@_pika_before_hooks.each(&.call(_pika_env))
            _pika_parsed = Pika::Params.parse(_pika_env)
            declared_params = validate_{{ sn.downcase.id }}!(_pika_parsed[:raw], _pika_parsed[:files])
            env = _pika_env
            env.response.content_type = "application/json"
            result = ({{ r[:handler].body }})
            @@_pika_after_hooks.each(&.call(_pika_env))
            {% if r[:verb] == "delete" %}
              # Sensible verb default: an empty delete body becomes 204 No Content,
              # unless the handler set an explicit non-200 status itself.
              if (result.nil? || result.to_s.empty?) && _pika_env.response.status_code == 200
                _pika_env.response.status_code = 204
              end
            {% end %}
            result ? result.to_s : nil
          rescue e : Pika::ValidationError
            @@_pika_fmt_validation.call(_pika_env, e)
          rescue e : Pika::Error
            @@_pika_fmt_error.call(_pika_env, e)
          end
        end

        # --- Response schemas -------------------------------------------------
        {% returns = r[:returns] %}
        {% hsrc    = r[:handler].body.stringify %}
        {% has_params = !r[:body_params].empty? %}
        {% scan_err = returns.empty? && (has_params ||
             hsrc.includes?("NotFoundError") || hsrc.includes?("UnauthorizedError") ||
             hsrc.includes?("ForbiddenError") || hsrc.includes?("ConflictError")) %}

        {% bare_error_return = false %}
        {% for ret in returns %}
          {% if ret[:entity] %}
            @@openapi_schemas[{{ ret[:entity] }}.pika_schema_name] = {{ ret[:entity] }}.pika_openapi_schema
          {% elsif ret[:status] >= 400 %}
            {% bare_error_return = true %}
          {% end %}
        {% end %}
        {% if scan_err || bare_error_return %}
          @@openapi_schemas["PikaError"] = Pika::OpenAPI.error_schema
        {% end %}

        # Register schemas for any nested-object params (plain or array-of).
        {% for p in r[:body_params] %}
          {% spt = p[:type].stringify %}
          {% s_base = spt.gsub(/ \| (?:::)?Nil/, "").strip %}
          {% s_scalarish = spt.includes?("String") || spt.includes?("Int32") || spt.includes?("Int64") || spt.includes?("Float64") || spt.includes?("Bool") || spt.includes?("UUID") || spt.includes?("Time") || spt.includes?("UploadedFile") %}
          {% unless s_scalarish %}
            {% if s_base.starts_with?("Array(") %}
              {% s_elem = s_base[6..-2] %}
              @@openapi_schemas[{{ s_elem.id }}.pika_schema_name] = {{ s_elem.id }}.pika_openapi_schema
            {% else %}
              @@openapi_schemas[{{ s_base.id }}.pika_schema_name] = {{ s_base.id }}.pika_openapi_schema
            {% end %}
          {% end %}
        {% end %}

        @@openapi_routes << Pika::OpenAPI::RouteSpec.new(
          method:  {{ r[:verb] }},
          path:    _pika_path,
          summary: {{ r[:summary] }},
          responses: [
            {% if returns.empty? %}
              {% succ = r[:verb] == "delete" ? 204 : 200 %}
              Pika::OpenAPI::ResponseSpec.new(status: {{ succ }}, description: Pika::OpenAPI.status_description({{ succ }}), schema_ref: nil),
              {% if has_params %}
                Pika::OpenAPI::ResponseSpec.new(status: 422, description: Pika::OpenAPI.status_description(422), schema_ref: "PikaError"),
              {% end %}
              {% if hsrc.includes?("NotFoundError") %}
                Pika::OpenAPI::ResponseSpec.new(status: 404, description: Pika::OpenAPI.status_description(404), schema_ref: "PikaError"),
              {% end %}
              {% if hsrc.includes?("UnauthorizedError") %}
                Pika::OpenAPI::ResponseSpec.new(status: 401, description: Pika::OpenAPI.status_description(401), schema_ref: "PikaError"),
              {% end %}
              {% if hsrc.includes?("ForbiddenError") %}
                Pika::OpenAPI::ResponseSpec.new(status: 403, description: Pika::OpenAPI.status_description(403), schema_ref: "PikaError"),
              {% end %}
              {% if hsrc.includes?("ConflictError") %}
                Pika::OpenAPI::ResponseSpec.new(status: 409, description: Pika::OpenAPI.status_description(409), schema_ref: "PikaError"),
              {% end %}
            {% else %}
              {% for ret in returns %}
                Pika::OpenAPI::ResponseSpec.new(
                  status:      {{ ret[:status] }},
                  description: Pika::OpenAPI.status_description({{ ret[:status] }}),
                  schema_ref:  {% if ret[:entity] %}{{ ret[:entity] }}.pika_schema_name{% elsif ret[:status] >= 400 %}"PikaError"{% else %}nil{% end %},
                ),
              {% end %}
            {% end %}
          ] of Pika::OpenAPI::ResponseSpec,
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
              required_fields: [
                {% for p in r[:body_params] %}{% if p[:required] %}
                  {% pt = p[:type].stringify %}{% base = pt.gsub(/ \| (?:::)?Nil/, "").strip %}
                  {% scalarish = pt.includes?("String") || pt.includes?("Int32") || pt.includes?("Int64") || pt.includes?("Float64") || pt.includes?("Bool") || pt.includes?("UUID") || pt.includes?("Time") || pt.includes?("UploadedFile") %}
                  {% is_arr = base.starts_with?("Array(") %}
                  {% fmt = pt.includes?("UploadedFile") ? "binary" : (pt.includes?("UUID") ? "uuid" : (pt.includes?("Time") ? "date-time" : "")) %}
                  {name: {{ p[:name].stringify }}, schema_type: {{ p[:oa_type] }}, format: {{ fmt }},
                   ref: {% if !is_arr && !scalarish %}{{ base.id }}.pika_schema_name{% else %}""{% end %},
                   items_ref: {% if is_arr && !scalarish %}{{ base[6..-2].id }}.pika_schema_name{% else %}""{% end %}},
                {% end %}{% end %}
              ] of {name: String, schema_type: String, format: String, ref: String, items_ref: String},
              optional_fields: [
                {% for p in r[:body_params] %}{% unless p[:required] %}
                  {% pt = p[:type].stringify %}{% base = pt.gsub(/ \| (?:::)?Nil/, "").strip %}
                  {% scalarish = pt.includes?("String") || pt.includes?("Int32") || pt.includes?("Int64") || pt.includes?("Float64") || pt.includes?("Bool") || pt.includes?("UUID") || pt.includes?("Time") || pt.includes?("UploadedFile") %}
                  {% is_arr = base.starts_with?("Array(") %}
                  {% fmt = pt.includes?("UploadedFile") ? "binary" : (pt.includes?("UUID") ? "uuid" : (pt.includes?("Time") ? "date-time" : "")) %}
                  {name: {{ p[:name].stringify }}, schema_type: {{ p[:oa_type] }}, format: {{ fmt }},
                   ref: {% if !is_arr && !scalarish %}{{ base.id }}.pika_schema_name{% else %}""{% end %},
                   items_ref: {% if is_arr && !scalarish %}{{ base[6..-2].id }}.pika_schema_name{% else %}""{% end %}},
                {% end %}{% end %}
              ] of {name: String, schema_type: String, format: String, ref: String, items_ref: String},
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

    # ---------------------------------------------------------------------------
    # request — in-process testing harness.
    #
    # Runs the full router → before-hook → validation → handler → after-hook chain
    # without binding a socket, and returns a structured Pika::TestResponse.
    #
    #   response = MyAPI.request(:post, "/v1/users", json: {name: "x"})
    #   response.status.should eq 201
    #   response.json["created"].should be_true
    # ---------------------------------------------------------------------------
    def self.request(method : String | Symbol, path : String, *,
                     json = nil, body : String = "", query : String = "",
                     headers : HTTP::Headers = HTTP::Headers.new) : Pika::TestResponse
      full_path = query.empty? ? path : "#{path}?#{query}"
      req = HTTP::Request.new(method.to_s.upcase, full_path, headers)

      if json
        req.body = IO::Memory.new(json.to_json)
        req.headers["Content-Type"] = "application/json" unless req.headers.has_key?("Content-Type")
      elsif !body.empty?
        req.body = IO::Memory.new(body)
      end

      io  = IO::Memory.new
      ctx = HTTP::Server::Context.new(req, HTTP::Server::Response.new(io))
      @@router.call(ctx)
      ctx.response.close

      io.rewind
      parsed = HTTP::Client::Response.from_io(io)
      Pika::TestResponse.new(parsed.status_code, parsed.headers, parsed.body)
    end

    def self.run(host : String = "0.0.0.0", port : Int32 = 3000, reuse_port : Bool = false,
                 shutdown_timeout : Time::Span = 30.seconds)
      server = HTTP::Server.new { |ctx| @@router.call(ctx) }
      address = server.bind_tcp(host, port, reuse_port: reuse_port)
      puts "Pika #{Pika::VERSION} listening on http://#{address}"

      # Graceful shutdown: on SIGTERM/SIGINT, stop accepting new connections,
      # drain in-flight requests (up to shutdown_timeout), then close.
      {% unless flag?(:win32) %}
        shutdown = ->(_sig : Signal) do
          puts "Pika draining (timeout #{shutdown_timeout})…"
          @@router.begin_draining
          drained = @@router.await_drain(shutdown_timeout)
          puts drained ? "Pika drained cleanly" : "Pika drain timed out; forcing close"
          server.close
        end
        Signal::TERM.trap(&shutdown)
        Signal::INT.trap(&shutdown)
      {% end %}

      server.listen
    end
  end
end
