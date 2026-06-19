require "json"
require "http/server"

module Pika
  # Response content negotiation. Handlers (and entities) produce JSON; when an
  # API opts in with the `formats` macro, Pika transcodes that JSON to XML or
  # MessagePack based on the request's Accept header (or a `?format=` override).
  #
  # Both encoders are hand-rolled over a parsed JSON::Any tree, so this adds no
  # external dependencies — consistent with Pika's zero-dep stance.
  module Serializer
    CONTENT_TYPES = {
      json:    "application/json",
      xml:     "application/xml",
      msgpack: "application/x-msgpack",
    }

    # Decide the response format for a request, restricted to the API's allowed
    # set. `?format=` wins; otherwise the Accept header; default :json.
    def self.negotiate(env : HTTP::Server::Context, allowed : Array(Symbol)) : Symbol
      if f = env.request.query_params["format"]?
        sym = case f
              when "xml"            then :xml
              when "msgpack", "mp"  then :msgpack
              when "json"           then :json
              else                       :json
              end
        return sym if allowed.includes?(sym)
      end

      accept = env.request.headers["Accept"]? || ""
      return :msgpack if accept.includes?("msgpack") && allowed.includes?(:msgpack)
      return :xml if accept.includes?("xml") && allowed.includes?(:xml)
      :json
    end

    # Parse a handler's JSON output; nil if it isn't JSON (e.g. plain text),
    # in which case the caller leaves the response untouched.
    def self.try_parse(body : String) : JSON::Any?
      return nil if body.empty?
      JSON.parse(body)
    rescue JSON::ParseException
      nil
    end

    # ---- XML -----------------------------------------------------------------

    def self.to_xml(any : JSON::Any, root : String = "response") : String
      String.build do |io|
        io << %(<?xml version="1.0" encoding="UTF-8"?>)
        xml_node(io, root, any)
      end
    end

    private def self.xml_node(io : IO, name : String, any : JSON::Any) : Nil
      tag = xml_name(name)
      case raw = any.raw
      when Hash
        io << "<" << tag << ">"
        raw.each { |k, v| xml_node(io, k, v) }
        io << "</" << tag << ">"
      when Array
        io << "<" << tag << ">"
        raw.each { |v| xml_node(io, "item", v) }
        io << "</" << tag << ">"
      when Nil
        io << "<" << tag << "/>"
      else
        io << "<" << tag << ">" << xml_escape(raw.to_s) << "</" << tag << ">"
      end
    end

    private def self.xml_escape(s : String) : String
      s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end

    # Coerce a JSON key into a valid XML element name.
    private def self.xml_name(name : String) : String
      cleaned = name.gsub(/[^a-zA-Z0-9_.\-]/, "_")
      cleaned = "_#{cleaned}" if cleaned.empty? || !cleaned[0].ascii_letter? && cleaned[0] != '_'
      cleaned
    end

    # ---- MessagePack ---------------------------------------------------------

    def self.to_msgpack(any : JSON::Any) : Bytes
      io = IO::Memory.new
      encode_msgpack(io, any)
      io.to_slice
    end

    private def self.encode_msgpack(io : IO, any : JSON::Any) : Nil
      case raw = any.raw
      when Nil
        io.write_byte(0xc0_u8)
      when Bool
        io.write_byte(raw ? 0xc3_u8 : 0xc2_u8)
      when Int64
        encode_int(io, raw)
      when Float64
        io.write_byte(0xcb_u8)
        io.write_bytes(raw, IO::ByteFormat::BigEndian)
      when String
        encode_str(io, raw)
      when Array
        encode_array_header(io, raw.size)
        raw.each { |v| encode_msgpack(io, v) }
      when Hash
        encode_map_header(io, raw.size)
        raw.each { |k, v| encode_str(io, k); encode_msgpack(io, v) }
      end
    end

    private def self.encode_int(io : IO, n : Int64) : Nil
      if 0 <= n <= 127
        io.write_byte(n.to_u8)               # positive fixint
      elsif -32 <= n <= -1
        io.write_byte((0xe0 | (n & 0x1f)).to_u8) # negative fixint
      else
        io.write_byte(0xd3_u8)               # int 64
        io.write_bytes(n, IO::ByteFormat::BigEndian)
      end
    end

    private def self.encode_str(io : IO, s : String) : Nil
      bytes = s.to_slice
      len = bytes.size
      if len < 32
        io.write_byte((0xa0 | len).to_u8)    # fixstr
      elsif len < 256
        io.write_byte(0xd9_u8); io.write_byte(len.to_u8)
      elsif len < 65536
        io.write_byte(0xda_u8); io.write_bytes(len.to_u16, IO::ByteFormat::BigEndian)
      else
        io.write_byte(0xdb_u8); io.write_bytes(len.to_u32, IO::ByteFormat::BigEndian)
      end
      io.write(bytes)
    end

    private def self.encode_array_header(io : IO, n : Int32) : Nil
      if n < 16
        io.write_byte((0x90 | n).to_u8)
      elsif n < 65536
        io.write_byte(0xdc_u8); io.write_bytes(n.to_u16, IO::ByteFormat::BigEndian)
      else
        io.write_byte(0xdd_u8); io.write_bytes(n.to_u32, IO::ByteFormat::BigEndian)
      end
    end

    private def self.encode_map_header(io : IO, n : Int32) : Nil
      if n < 16
        io.write_byte((0x80 | n).to_u8)
      elsif n < 65536
        io.write_byte(0xde_u8); io.write_bytes(n.to_u16, IO::ByteFormat::BigEndian)
      else
        io.write_byte(0xdf_u8); io.write_bytes(n.to_u32, IO::ByteFormat::BigEndian)
      end
    end
  end
end
