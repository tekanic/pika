module Pika
  # How the API version is communicated by the client.
  #
  #   Path   (default) — version is a URL prefix:         /v1/users
  #   Header           — custom request header:            X-Api-Version: v1
  #   Accept           — vendor media type:                Accept: application/vnd.<vendor>.v1+json
  #
  enum VersionStrategy
    Path
    Header
    Accept
  end

  # Extracts the requested version string from a request context given
  # the strategy and (for Accept) the vendor name.
  # Returns nil for the Path strategy — the version is already encoded in the URL.
  def self.version_from_request(ctx : HTTP::Server::Context,
                                strategy : VersionStrategy,
                                vendor : String) : String?
    case strategy
    when VersionStrategy::Path
      nil
    when VersionStrategy::Header
      ctx.request.headers["X-Api-Version"]?
    when VersionStrategy::Accept
      accept = ctx.request.headers["Accept"]? || ""
      if m = accept.match(/application\/vnd\.#{Regex.escape(vendor)}[.\-](v[\w]+)\+/)
        m[1]
      end
    end
  end
end
