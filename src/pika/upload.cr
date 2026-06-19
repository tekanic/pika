module Pika
  # A file received via multipart/form-data. The content is buffered in memory,
  # which suits typical avatar/document uploads; very large uploads should be
  # streamed at the handler level instead.
  struct UploadedFile
    getter filename : String
    getter content_type : String
    getter content : Bytes

    def initialize(@filename : String, @content_type : String, @content : Bytes)
    end

    # Placeholder used as the typed default before validation confirms presence.
    def self.empty : UploadedFile
      new("", "application/octet-stream", Bytes.empty)
    end

    def size : Int32
      @content.size
    end

    def empty? : Bool
      @content.empty? && @filename.empty?
    end

    # The content decoded as a UTF-8 string (useful for text uploads / tests).
    def gets_to_string : String
      String.new(@content)
    end
  end
end
