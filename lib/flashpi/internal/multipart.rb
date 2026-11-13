# frozen_string_literal: true

module Flashpi
  module Internal
    # The multipart/form-data body of a .p12 upload, for `issuers.certificates.upload` and
    # `issuer_onboardings.create`: a `password` field, then a `file` part.
    #
    # It is encoded once, so every retry sends the same bytes (an IO could not be read twice), and
    # kept in a {Secret}: its `inspect` lists only the part names, never the .p12 or its password.
    #
    # @api private
    class Multipart
      # Largest .p12 the API accepts (413 `payload_too_large` above it).
      MAX_CERTIFICATE_BYTES = 1_048_576
      DEFAULT_FILENAME = "certificate.p12"
      CONTENT_TYPE = "application/x-pkcs12"
      PIECE = 65_536

      # @return [String]
      attr_reader :content_type

      # The body of a certificate upload: `{ file:, password:, filename: }`.
      #
      # Raises before anything is sent: Flashpi::Error for a password that is not a String, an
      # empty file or one over 1 MiB; TypeError for an upload that is not a Hash, a file that is
      # neither a String of bytes nor an IO, or a filename that is not a String. Error trackers
      # can record the local variables of the method that raises, so the errors are raised by
      # {refuse!}, whose frame holds neither the .p12 nor its password.
      #
      # @param upload [Hash]
      # @return [Multipart]
      def self.certificate(upload)
        refuse!(TypeError, "The certificate upload must be a Hash with file and password") unless upload.is_a?(Hash)

        password = member(upload, :password)
        refuse!(Error, "The certificate password must be a String") unless password.is_a?(String)

        filename = member(upload, :filename) || DEFAULT_FILENAME
        refuse!(TypeError, "The certificate filename must be a String") unless filename.is_a?(String)

        new(password, read(member(upload, :file)), filename)
      end

      # @api private
      def self.member(upload, name)
        upload.key?(name) ? upload[name] : upload[name.to_s]
      end

      # The bytes of the file: a String as it is, an IO read to its end in pieces, up to one byte
      # past the largest certificate, so a big or wrong file is refused without loading it whole.
      #
      # @api private
      def self.read(file)
        content = file.is_a?(String) ? file.b : read_io(file)
        refuse!(Error, "The certificate file is empty") if content.empty?
        if content.bytesize > MAX_CERTIFICATE_BYTES
          refuse!(Error, "The certificate file has more than #{MAX_CERTIFICATE_BYTES} bytes, the most the API accepts")
        end
        content
      end

      # @api private
      def self.read_io(file)
        unless file.respond_to?(:read)
          refuse!(TypeError,
                  "The certificate file must be a String of bytes or an IO opened in binary mode, not #{file.class}")
        end

        content = String.new(encoding: Encoding::BINARY)
        while content.bytesize <= MAX_CERTIFICATE_BYTES
          chunk = file.read([PIECE, MAX_CERTIFICATE_BYTES + 1 - content.bytesize].min)
          break if chunk.nil?
          refuse!(TypeError, "The read method of the certificate file returned #{chunk.class}, not a String") unless chunk.is_a?(String)
          break if chunk.empty?

          content << chunk.b
        end
        content
      end

      # Raises from a frame that holds only the error.
      #
      # @api private
      def self.refuse!(error, message)
        raise error, message
      end

      def initialize(password, content, filename)
        boundary = "flashpi-#{SecureRandom.hex(16)}"
        boundary = "flashpi-#{SecureRandom.hex(16)}" while content.include?(boundary) || password.b.include?(boundary)
        @content_type = "multipart/form-data; boundary=#{boundary}"
        @body = Secret.new(encode(boundary, password, content, filename).freeze)
        freeze
      end

      # @return [String] the encoded body
      def content
        @body.reveal
      end

      # Only the part names: the values are a .p12 and its password.
      def inspect
        "#<#{self.class.name} fields=[\"password\"] files=[\"file\"]>"
      end

      private

      def encode(boundary, password, content, filename)
        body = String.new(encoding: Encoding::BINARY)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"password\"\r\n\r\n"
        body << password.b << "\r\n"
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{escape(filename)}\"\r\n"
        body << "Content-Type: #{CONTENT_TYPE}\r\n\r\n"
        body << content << "\r\n"
        body << "--#{boundary}--\r\n"
      end

      # As browsers write a file name (WHATWG): quotes and line breaks percent-encoded.
      def escape(filename)
        filename.b.gsub("\"", "%22").gsub("\r", "%0D").gsub("\n", "%0A")
      end
    end
  end
end
