require "json"
require "http/server"

module Pika
  # Response content negotiation. Handlers (and entities) produce JSON; when an
  # API opts in with the `formats` macro, Pika transcodes that JSON to
  # MessagePack based on the request's Accept header (or a `?format=` override).
  #
  # The encoder/decoder are hand-rolled over a parsed JSON::Any tree, so this
  # adds no external dependencies — consistent with Pika's zero-dep stance.
  module Serializer
    CONTENT_TYPES = {
      json:    "application/json",
      msgpack: "application/x-msgpack",
    }

    # Decide the response format for a request, restricted to the API's allowed
    # set. `?format=` wins; otherwise the Accept header; default :json.
    def self.negotiate(env : HTTP::Server::Context, allowed : Array(Symbol)) : Symbol
      if f = env.request.query_params["format"]?
        sym = case f
              when "msgpack", "mp" then :msgpack
              else                      :json
              end
        return sym if allowed.includes?(sym)
      end

      accept = env.request.headers["Accept"]? || ""
      return :msgpack if accept.includes?("msgpack") && allowed.includes?(:msgpack)
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

    # ---- MessagePack decode --------------------------------------------------

    # Decode a MessagePack payload into a JSON::Any tree. Types are preserved, so
    # this round-trips losslessly with to_msgpack. Raises on malformed input.
    def self.from_msgpack(bytes : Bytes) : JSON::Any
      decode_msgpack(IO::Memory.new(bytes))
    end

    private def self.decode_msgpack(io : IO) : JSON::Any
      byte = io.read_byte
      raise "msgpack: unexpected end of input" unless byte

      case byte
      when 0x00..0x7f then JSON::Any.new(byte.to_i64)                # positive fixint
      when 0xe0..0xff then JSON::Any.new(byte.to_i8!.to_i64)         # negative fixint
      when 0x80..0x8f then mp_map(io, (byte & 0x0f).to_i)           # fixmap
      when 0x90..0x9f then mp_array(io, (byte & 0x0f).to_i)         # fixarray
      when 0xa0..0xbf then JSON::Any.new(mp_str(io, (byte & 0x1f).to_i)) # fixstr
      when 0xc0 then JSON::Any.new(nil)
      when 0xc2 then JSON::Any.new(false)
      when 0xc3 then JSON::Any.new(true)
      when 0xca then JSON::Any.new(io.read_bytes(Float32, IO::ByteFormat::BigEndian).to_f64)
      when 0xcb then JSON::Any.new(io.read_bytes(Float64, IO::ByteFormat::BigEndian))
      when 0xcc then JSON::Any.new(io.read_byte.not_nil!.to_i64)
      when 0xcd then JSON::Any.new(io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i64)
      when 0xce then JSON::Any.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i64)
      when 0xcf then JSON::Any.new(io.read_bytes(UInt64, IO::ByteFormat::BigEndian).to_i64!)
      when 0xd0 then JSON::Any.new(io.read_bytes(Int8, IO::ByteFormat::BigEndian).to_i64)
      when 0xd1 then JSON::Any.new(io.read_bytes(Int16, IO::ByteFormat::BigEndian).to_i64)
      when 0xd2 then JSON::Any.new(io.read_bytes(Int32, IO::ByteFormat::BigEndian).to_i64)
      when 0xd3 then JSON::Any.new(io.read_bytes(Int64, IO::ByteFormat::BigEndian))
      when 0xd9 then JSON::Any.new(mp_str(io, io.read_byte.not_nil!.to_i))
      when 0xda then JSON::Any.new(mp_str(io, io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i))
      when 0xdb then JSON::Any.new(mp_str(io, io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i))
      when 0xdc then mp_array(io, io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i)
      when 0xdd then mp_array(io, io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i)
      when 0xde then mp_map(io, io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_i)
      when 0xdf then mp_map(io, io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i)
      else
        raise "msgpack: unsupported byte 0x#{byte.to_s(16)}"
      end
    end

    private def self.mp_str(io : IO, len : Int32) : String
      bytes = Bytes.new(len)
      io.read_fully(bytes)
      String.new(bytes)
    end

    private def self.mp_array(io : IO, n : Int32) : JSON::Any
      arr = Array(JSON::Any).new(n)
      n.times { arr << decode_msgpack(io) }
      JSON::Any.new(arr)
    end

    private def self.mp_map(io : IO, n : Int32) : JSON::Any
      h = {} of String => JSON::Any
      n.times do
        k = decode_msgpack(io)
        h[k.as_s? || k.to_s] = decode_msgpack(io)
      end
      JSON::Any.new(h)
    end
  end
end
