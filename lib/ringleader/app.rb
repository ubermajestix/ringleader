module Ringleader

  # A configured application.
  #
  # Listens on a port, starts and runs the app process on demand, and proxies
  # network data to the process.
  class App
    include Celluloid::IO
    include Celluloid::Logger

    def initialize(config)
      @config = config
      @process = Process.new(config)
      async.enable unless config.disabled
      start if config.run_on_load
    end

    def name
      @config.name
    end

    def enabled?
      @enabled
    end

    def running?
      @process.running?
    end

    def start
      return if @process.running?
      info "starting #{@config.name}..."
      if @process.start
        start_activity_timer
      end
    end

    def stop(forever=false)
      return unless @process.running?
      info "stopping #{@config.name}..."

      if forever
        # stop processing requests
        @server.close
        @server = nil
      end

      stop_activity_timer
      @process.stop
    end

    def restart
      stop
      start
    end

    def enable
      return if @server
      @server = TCPServer.new @config.host, @config.server_port
      @enabled = true
      async.run
    rescue Errno::EADDRINUSE
      error "could not bind to #{@config.host}:#{@config.server_port} for #{@config.name}!"
      @server = nil
    end

    def disable
      info "disabling #{@config.name}..."
      return unless @server
      stop_activity_timer
      @server.close
      @server = nil
      @process.stop
      @enabled = false
    end

    def close_server_socket
      @server.close if @server && !@server.closed?
      @server = nil
    end
    finalizer :close_server_socket

    def run
      info "listening for connections for #{@config.name} on #{@config.host}:#{@config.server_port}"
      loop { async.handle_connection @server.accept }
    rescue IOError
      @server.close if @server
    end

    def handle_connection(socket)
      _, port, host = socket.peeraddr
      debug "received connection from #{host}:#{port}"

      started = @process.start
      if started
        async.proxy_to_app socket
        reset_activity_timer
      else
        error "could not start app"
        socket.close
      end
    end

    def proxy_to_app(upstream)
      debug "proxying to #{@config.host}:#{@config.app_port}"

      downstream = TCPSocket.new(@config.host, @config.app_port)
      async.proxy downstream, upstream
      async.proxy upstream, downstream

    rescue IOError, SystemCallError => e
      error "could not proxy to #{@config.host}:#{@config.app_port}: #{e}"
      upstream.close
    end

    def start_activity_timer
      return if @activity_timer || @config.idle_timeout == 0
      @activity_timer = every @config.idle_timeout do
        if @process.running?
          info "#{@config.name} has been idle for #{@config.idle_timeout} seconds, shutting it down"
          @process.stop
        end
      end
    end

    def reset_activity_timer
      start_activity_timer
      @activity_timer.reset if @activity_timer
    end

    def stop_activity_timer
      if @activity_timer
        @activity_timer.cancel
        @activity_timer = nil
      end
    end

    def proxy(from, to)
      ::IO.copy_stream from, to
    rescue IOError, SystemCallError
      # from or to were closed or connection was reset
    ensure
      from.close unless from.closed?
      to.close unless to.closed?
    end

  end
end
