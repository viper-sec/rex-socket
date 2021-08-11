# -*- coding: binary -*-
require 'rex/socket'
require 'openssl'
###
#
# This class provides methods for interacting with an SSL TCP client
# connection.
#
###
module Rex::Socket::SslTcp

begin

  include Rex::Socket::Tcp

  ##
  #
  # Factory
  #
  ##

  #
  # Creates an SSL TCP instance.
  #
  def self.create(hash = {})
    hash['SSL'] = true
    self.create_param(Rex::Socket::Parameters.from_hash(hash))
  end

  #
  # Set the SSL flag to true,
  # create placeholders for client certs,
  # call the base class's create_param routine.
  #
  def self.create_param(param)
    param.ssl   = true
    Rex::Socket::Tcp.create_param(param)
  end

  ##
  #
  # Class initialization
  #
  ##

  def self.system_ssl_methods
    ssl_context = OpenSSL::SSL::SSLContext
    if ssl_context.const_defined? :METHODS_MAP
      ssl_context.const_get(:METHODS_MAP).keys
    else
      ssl_context::METHODS
    end
  end

  def self.supported_ssl_methods
    @@methods ||= ['Auto', 'TLS'] + system_ssl_methods
      .reject { |method| method.match(/server|client/) }
      .select {|m| OpenSSL::SSL::SSLContext.new(m) && true rescue false} \
      .map {|m| m.to_s.sub(/v/, '').sub('_', '.')}
  end

  #
  # Initializes the SSL socket.
  #
  def initsock(params = nil)
    super

    # Default to SSLv23 (automatically negotiate)
    version = :SSLv23

    # Let the caller specify a particular SSL/TLS version
    if params
      case params.ssl_version
      when 'SSL2', :SSLv2
        version = :SSLv2
      # 'TLS' will be the new name for autonegotation with newer versions of OpenSSL
      when 'SSL23', :SSLv23, 'TLS', 'Auto'
        version = :SSLv23
      when 'SSL3', :SSLv3
        version = :SSLv3
      when 'TLS1','TLS1.0', :TLSv1
        version = :TLSv1
      when 'TLS1.1', :TLSv1_1
        version = :TLSv1_1
      when 'TLS1.2', :TLSv1_2
        version = :TLSv1_2
      end
    end

    # Raise an error if no selected versions are supported
    unless Rex::Socket::SslTcp.system_ssl_methods.include? version
      raise ArgumentError,
        "This version of Ruby does not support the requested SSL/TLS version #{params.ssl_version}"
    end

    # Try intializing the socket with this SSL/TLS version
    # This will throw an exception if it fails
    initsock_with_ssl_version(params, version)

    # Track the SSL version
    self.ssl_negotiated_version = version
  end

  def initsock_with_ssl_version(params, version)
    # Build the SSL connection
    self.sslctx  = OpenSSL::SSL::SSLContext.new(version)

    # Configure client certificate
    if params and params.ssl_client_cert
      self.sslctx.cert = OpenSSL::X509::Certificate.new(params.ssl_client_cert)
    end

    # Configure client key
    if params and params.ssl_client_key
      self.sslctx.key = OpenSSL::PKey::RSA.new(params.ssl_client_key)
    end

    # Configure the SSL context
    # TODO: Allow the user to specify the verify mode callback
    # Valid modes:
    #  VERIFY_CLIENT_ONCE
    #  VERIFY_FAIL_IF_NO_PEER_CERT
    #  VERIFY_NONE
    #  VERIFY_PEER
    if params.ssl_verify_mode
      self.sslctx.verify_mode = OpenSSL::SSL.const_get("VERIFY_#{params.ssl_verify_mode}".intern)
    else
      # Could also do this as graceful faildown in case a passed verify_mode is not supported
      self.sslctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    end

    self.sslctx.options = OpenSSL::SSL::OP_ALL

    if params.ssl_cipher
      self.sslctx.ciphers = params.ssl_cipher
    end

    # Set the verification callback
    self.sslctx.verify_callback = Proc.new do |valid, store|
      self.peer_verified = valid
      true
    end

    # Tie the context to a socket
    self.sslsock = OpenSSL::SSL::SSLSocket.new(self, self.sslctx)

    # If peerhost looks like a hostname, set the undocumented 'hostname'
    # attribute on sslsock, which enables the Server Name Indication (SNI)
    # extension
    self.sslsock.hostname = self.peerhost if !Rex::Socket.dotted_ip?(self.peerhost)

    # Force a negotiation timeout
    begin
    Timeout.timeout(params.timeout) do
      if not allow_nonblock?
        dlog("initsock_with_ssl_version: not allow_nonblock")
        self.sslsock.connect
      else
        begin
          self.sslsock.connect_nonblock
        # Ruby 1.8.7 and 1.9.0/1.9.1 uses a standard Errno
        rescue ::Errno::EAGAIN, ::Errno::EWOULDBLOCK
            IO::select(nil, nil, nil, 0.10)
            retry

        # Ruby 1.9.2+ uses IO::WaitReadable/IO::WaitWritable
        rescue ::Exception => e
          if ::IO.const_defined?('WaitReadable') and e.kind_of?(::IO::WaitReadable)
            IO::select( [ self.sslsock ], nil, nil, 0.10 )
            retry
          end

          if ::IO.const_defined?('WaitWritable') and e.kind_of?(::IO::WaitWritable)
            IO::select( nil, [ self.sslsock ], nil, 0.10 )
            retry
          end

          raise e
        end
      end
    end

    rescue ::Timeout::Error
      raise Rex::ConnectionTimeout.new(params.peerhost, params.peerport)
    end
  end

  ##
  #
  # Stream mixin implementations
  #
  ##

  #
  # Writes data over the SSL socket.
  #
  def write(buf, opts = {})
    return sslsock.write(buf) if not allow_nonblock?

    total_sent   = 0
    total_length = buf.length
    block_size   = 102400
    retry_time   = 0.01

    begin
      while( total_sent < total_length )

        data = buf[total_sent, block_size]
        sent = sslsock.write_nonblock( data )
        if sent > 0
          total_sent += sent
        end
      end

    rescue ::IOError, ::Errno::EPIPE
      return nil

    # Ruby 1.8.7 and 1.9.0/1.9.1 uses a standard Errno
    rescue ::Errno::EAGAIN, ::Errno::EWOULDBLOCK
      Rex::ThreadSafe.select( nil, [ self.sslsock ], nil, 0.01 )
      # Decrement the block size to handle full sendQs better
      block_size = [block_size/2,1024].max
      # Try to write the data again
      retry

    # Ruby 1.9.2+ uses IO::WaitReadable/IO::WaitWritable
    rescue ::Exception => e
      if ::IO.const_defined?('WaitReadable') and e.kind_of?(::IO::WaitReadable)
        IO::select( [ self.sslsock ], nil, nil, retry_time )
        retry
      end

      if ::IO.const_defined?('WaitWritable') and e.kind_of?(::IO::WaitWritable)
        IO::select( nil, [ self.sslsock ], nil, retry_time )
        retry
      end

      # Another form of SSL error, this is always fatal
      if e.kind_of?(::OpenSSL::SSL::SSLError)
        return nil
      end

      # Bubble the event up to the caller otherwise
      raise e
    end

    total_sent
  end

  #
  # Reads data from the SSL socket.
  #
  def read(length = nil, opts = {})
    if not allow_nonblock?
      length = 102400 unless length
      begin
        return sslsock.sysread(length)
      rescue ::IOError, ::Errno::EPIPE, ::OpenSSL::SSL::SSLError
        return nil
      end
      return
    end

    block_size   = 102400
    begin
      while true
        return sslsock.read_nonblock( block_size )
      end

    rescue ::IOError, ::Errno::EPIPE
      return nil

    # Ruby 1.8.7 and 1.9.0/1.9.1 uses a standard Errno
    rescue ::Errno::EAGAIN, ::Errno::EWOULDBLOCK
      Rex::ThreadSafe.select( [ self.sslsock ], nil, nil, 0.01 )
      # Decrement the block size to handle full sendQs better
      block_size = [block_size/2,1024].max
      # Try to write the data again
      retry

    # Ruby 1.9.2+ uses IO::WaitReadable/IO::WaitWritable
    rescue ::Exception => e
      if ::IO.const_defined?('WaitReadable') and e.kind_of?(::IO::WaitReadable)
        IO::select( [ self.sslsock ], nil, nil, 0.01 )
        retry
      end

      if ::IO.const_defined?('WaitWritable') and e.kind_of?(::IO::WaitWritable)
        IO::select( nil, [ self.sslsock ], nil, 0.01 )
        retry
      end

      # Another form of SSL error, this is always fatal
      if e.kind_of?(::OpenSSL::SSL::SSLError)
        return nil
      end

      raise e
    end

  end


  #
  # Closes the SSL socket.
  #
  def close
    sslsock.close rescue nil
    super
  end

  #
  # Ignore shutdown requests
  #
  def shutdown(how=0)
    # Calling shutdown() on an SSL socket can lead to bad things
    # Cause of http://metasploit.com/dev/trac/ticket/102
  end

  #
  # Access to peer cert
  #
  def peer_cert
    sslsock.peer_cert if sslsock
  end

  #
  # Access to peer cert chain
  #
  def peer_cert_chain
    sslsock.peer_cert_chain if sslsock
  end

  #
  # Access to client cert
  #
  def client_cert
    sslsock.sslctx.cert if sslsock
  end

  #
  # Access to client key
  #
  def client_key
    sslsock.sslctx.key if sslsock
  end

  #
  # Access to the current cipher
  #
  def cipher
    sslsock.cipher if sslsock
  end

  #
  # Prevent a sysread from the bare socket
  #
  def sysread(*args)
    raise RuntimeError, "Invalid sysread() call on SSL socket"
  end

  #
  # Prevent a sysread from the bare socket
  #
  def syswrite(*args)
    raise RuntimeError, "Invalid syswrite() call on SSL socket"
  end

  #
  # This flag determines whether to use the non-blocking openssl
  # API calls when they are available. This is still buggy on
  # Linux/Mac OS X, but is required on Windows
  #
  def allow_nonblock?
    avail = self.sslsock.respond_to?(:accept_nonblock)
    if avail and Rex::Compat.is_windows
      return true
    end
    false
  end

  attr_reader :peer_verified # :nodoc:
  attr_reader :ssl_negotiated_version # :nodoc:
  attr_accessor :sslsock, :sslctx, :sslhash # :nodoc:

  def type?
    return 'tcp-ssl'
  end

protected

  attr_writer :peer_verified # :nodoc:
  attr_writer :ssl_negotiated_version # :nodoc:


rescue LoadError
end

end

