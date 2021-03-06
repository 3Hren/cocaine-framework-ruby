require 'logger'
require 'msgpack'
require 'optparse'
require 'uri'

require 'celluloid'
require 'celluloid/io'

module Cocaine
  # [Detail]
  # For dynamic method creation.
  class Meta
    def metaclass
      class << self
        self
      end
    end
  end

  METHOD_ID = 0
  TX_TREE_ID = 1
  RX_TREE_ID = 2

  module Default
    module Locator
      def host
        @host || '::'
      end

      def host=(host)
        @host = host
      end

      def port
        @port || 10053
      end

      def port=(port)
        @port = port
      end

      def endpoints
        @endpoints || ['::', 10053]
      end

      def endpoints=(endpoints)
        @endpoints = endpoints
      end

      module_function :host, :host=, :port, :port=, :endpoints, :endpoints=

      API = {
          0 => [
              'resolve',
              {},
              {
                  0 => ['write', nil, {}],
                  1 => ['error', {}, {}],
                  2 => ['close', {}, {}]
              }
          ]
      }
    end
  end

  module RPC
    module Version1
      CONTROL_CHANNEL = 1

      module Messages
        HANDSHAKE, HEARTBEAT, TERMINATE, INVOKE, CHUNK, ERROR, CHOKE = (0..6).to_a
      end

      class Dispatcher
        def handshake(uuid)
          [CONTROL_CHANNEL, 0, [uuid]]
        end

        def heartbeat
          [CONTROL_CHANNEL, 1, []]
        end

        def terminate(errno, reason)
          [CONTROL_CHANNEL, 2, [errno, reason]]
        end

        def process(span, id)
          case id
            when 1
              :heartbeat
            when 2
              :terminate
            when 3
              :invoke
            when 4
              :chunk
            when 5
              :error
            when 6
              :choke
            else
              :unknown
          end
        end
      end
    end

    module Version2
    end

    def self.dispatcher(version)
      case version
        when 0
          Version1::Dispatcher.new
        else
          raise Exception.new 'unsupported version number'
      end
    end

    CHUNK = 4
    ERROR = 5
    CHOKE = 6

    RXTREE = {
        CHUNK => ['write', nil, {}],
        ERROR => ['error', {}, {}],
        CHOKE => ['close', {}, {}]
    }
    TXTREE = RXTREE
  end

  # [Detail]
  # Base class for shared read channel state.
  class Mailbox
    def initialize(queue)
      @queue = queue
    end
  end

  # [API]
  # Read-only part for reader shared state.
  # Allows to receive unpacked objects from the channel.
  # Returns tuple with message id and payload.
  class RxMailbox < Mailbox
    def recv(timeout=30.0)
      @queue.receive timeout
    end
  end

  # [Detail]
  # Write-only part for reader shared state.
  class TxMailbox < Mailbox
    def initialize(queue, tree, session, &block)
      super queue

      @tree = Hash.new
      tree.each do |id, (method, txtree, rxtree)|
        @tree[id] = [method.to_sym, txtree]
      end

      @session = session
      @close = block
    end

    def push(id, payload)
      method, txtree = @tree[id]
      if txtree && txtree.empty?
        LOG.debug "Closing RX channel #{self}"
        @close.call @session
      end

      @queue << [method, payload]
    end

    def error(errno, reason)
      @queue << [:error, [errno, reason]]

      LOG.debug "Closing RX channel #{self} due to error: [#{errno}] #{reason}"
      @close.call @session
    end
  end

  # [Detail]
  # Reader shared state, that acts like channel. Need for channel splitting between the library and a user.
  class RxChannel
    attr_reader :tx, :rx

    def initialize(tree, session, &block)
      queue = Celluloid::Mailbox.new
      @tx = TxMailbox.new queue, tree, session, &block
      @rx = RxMailbox.new queue
    end
  end

  # [API]
  # Writer channel. Patches itself with current state, providing methods described in tx tree.
  class TxChannel < Meta
    def initialize(tree, session, socket)
      @session = session
      @socket = socket
      @tree = nil
      rebind tree
    end

    private
    def push(id, *args)
      LOG.debug "<- [#{@session}, #{id}, #{args}]"
      @socket.write MessagePack.pack [@session, id, args]
      rebind @tree[id][Cocaine::TX_TREE_ID]
    end

    def rebind(new)
      if new.nil?
        LOG.debug 'Found recursive leaf - doing nothing with tx channel'
        return
      end

      old = @tree || Hash.new
      old.each do |id, (method, txtree, rxtree)|
        LOG.debug "Removed '#{method}' method for tx channel"
        self.metaclass.send(:define_method, method) do |*|
          raise Exception.new "Method '#{method}' is removed"
        end
      end

      new ||= Hash.new
      new.each do |id, (method, txtree, rxtree)|
        LOG.debug "Defined '#{method}' method for tx channel"
        self.metaclass.send(:define_method, method) do |*args|
          push id, *args
        end
      end

      @tree = new
    end
  end

  class ServiceError < IOError
  end

  # [API]
  # Service actor, which can define itself via its dispatch tree.
  class DefinedService < Meta
    include Celluloid::IO

    attr_reader :name

    def initialize(name, endpoints, dispatch)
      @name = name
      @framing = dispatch
      @counter = 1
      @sessions = Hash.new

      LOG.debug "Initializing '#{name}' service - with possible endpoints: #{endpoints}"
      endpoints.each do |host, port|
        LOG.debug "Trying to connect to '#{name}' at '[#{host}]:#{port}'"
        begin
          @endpoint = [host, port]
          @socket = TCPSocket.new(host, port)
          break
        rescue IOError => err
          LOG.warn "Failed: #{err}"
        end
      end

      dispatch.each do |id, (method, txtree, rxtree)|
        LOG.debug "Defined '#{method}' method for service #{self}"
        self.metaclass.send(:define_method, method) do |*args, **headers|
          return invoke(id, *args, **headers)
        end
      end

      async.run
    end

    protected
    def reinitialize; end

    private
    def run
      LOG.debug "Service '#{@name}' is running"

      unpacker = MessagePack::Unpacker.new
      loop do
        data = @socket.readpartial(4096)
        unpacker.feed_each(data) do |decoded|
          async.received *decoded
        end
      end
    rescue EOFError => err
      LOG.warn "Service '#{@name}' has lost connection with the Cloud"
      @socket = nil
      @sessions.each do |session, (tx, rx)|
        rx.error 1, err.message
      end
    end

    def received(span, id, payload, *extra)
      LOG.debug "-> [#{span}, #{id}, #{payload}, #{extra}]"
      tx, rx = @sessions[span]
      if rx
        rx.push id, payload
      else
        LOG.warn "Received message to closed session: [#{span}, #{id}, #{payload}]"
      end
    end

    def invoke(id, *args, **headers)
      reinitialize if @socket.nil?

      method, txtree, rxtree = @framing[id]
      LOG.debug "Invoking #{@name} '#{method}' method with #{id} id and #{args} args with #{headers} headers"

      txchan = TxChannel.new txtree, @counter, @socket
      rxchan = RxChannel.new rxtree, @counter do |session|
        @sessions.delete session
      end

      hpack = []
      headers.each do |name, value|
        hpack.push [false, name, value]
      end

      LOG.debug "<- [#{@counter}, #{id}, #{args}, #{hpack}]"
      message = MessagePack.pack([@counter, id, args, hpack])
      @socket.write message
      @sessions[@counter] = [txchan, rxchan.tx]
      @counter += 1
      return txchan, rxchan.rx
    end
  end

  # [API]
  class Locator < DefinedService
    def initialize(endpoints = nil)
      endpoints ||= [[Default::Locator.host, Default::Locator.port]]

      super :locator, endpoints, Default::Locator::API
    end
  end

  # [API]
  # Service class. All you need is name and (optionally) locator endpoints.
  class Service < DefinedService
    def initialize(name, endpoints = nil)
      @location = endpoints

      locator = Locator.new @location
      tx, rx = locator.resolve name
      id, payload = rx.recv
      if id == :error
        raise ServiceError.new payload
      end
      locator.terminate

      endpoints, version, dispatch = payload
      super name, endpoints, dispatch
    end

    protected
    def reinitialize
      initialize @name
    end
  end

  # [Detail]
  # Special worker actor for RAII.
  class WorkerActor
    include Celluloid

    def initialize(block)
      @block = block
    end

    def execute(tx, rx)
      @block.call tx, rx
      yield
    end
  end

  # [API]
  # Worker class.
  class Worker
    include Celluloid
    include Celluloid::IO

    execute_block_on_receiver :on
    finalizer :finalize

    def initialize(options)
      @app      = options[:app]
      @uuid     = options[:uuid]
      @endpoint = options[:endpoint]

      @framing = RPC::dispatcher options[:protocol]

      @actors = Hash.new
      @sessions = Hash.new

      timeout = 60.0

      @disown = after timeout do
        LOG.fatal "Terminating due to disown timer expiration (#{timeout} sec)"

        exit Errno.ETIMEDOUT
      end
    end

    def on(event, &block)
      @actors[event.to_s] = WorkerActor.new block
    end

    def run
      LOG.debug "Starting worker '#{@app}' with uuid '#{@uuid}' at '#{@endpoint}'"

      @socket = UNIXSocket.open @endpoint
      async.handshake
      async.health
      async.serve
    end

    private
    def handshake
      LOG.debug '<- Handshake'

      @socket.write MessagePack::pack @framing.handshake @uuid
    end

    def health
      heartbeat = MessagePack::pack @framing.heartbeat

      loop do
        LOG.debug '<- Heartbeat'

        @socket.write heartbeat
        sleep 5.0
      end
    end

    def serve
      unpacker = MessagePack::Unpacker.new

      loop do
        data = @socket.readpartial 4096
        unpacker.feed_each data do |decoded|
          async.received *decoded
        end
      end
    end

    def received(span, id, payload, *extra)
      LOG.debug "-> Message(#{span}, #{id}, #{payload}, #{extra})"

      case @framing.process span, id
        when :heartbeat
          @disown.reset
        when :terminate
          terminate *payload
        when :invoke
          invoke span, *payload
        when :chunk
          push span, id, *payload
        when :error
          push span, id, *payload
          revoke span
        when :choke
          push span, id, []
          revoke span
        else
          LOG.warn "Received unknown message: [#{span}, #{id}, #{payload}]"
      end
    end

    def invoke(session, event)
      LOG.debug "Invoking new #{session} channel with #{event} event"

      actor = @actors[event]
      txchan = TxChannel.new RPC::TXTREE, session, @socket
      rxchan = RxChannel.new RPC::RXTREE, session do |session_|
        @sessions.delete session_
      end

      if actor
        @sessions[session] = [txchan, rxchan.tx]
        actor.execute txchan, rxchan.rx do
          LOG.debug '<- Choke'
          txchan.close
        end
      else
        LOG.warn "Event '#{event}' is not registered"
        txchan.error -1, "event '#{event}' is not registered"
      end
    end

    def push(session, id, *payload)
      tx, rx = @sessions[session]
      if rx
        rx.push id, *payload
      else
        raise Exception.new "received push event on unknown #{session} session"
      end
    end

    def revoke(span)
      LOG.debug "Closing #{span} channel"
      @sessions.delete span
    end

    def terminate(errno, reason)
      LOG.warn "Terminating [#{errno}]: #{reason}"

      @socket.write MessagePack::pack @framing.terminate errno, reason
      exit errno
    end

    def finalize
      if @socket
        @socket.close
      end
    end
  end

  # [API].
  class WorkerFactory
    def self.create
      options = {}
      options[:protocol] = 0

      OptionParser.new do |opts|
        opts.banner = 'Usage: <worker.rb> --app NAME --locator ADDRESS --uuid UUID --endpoint ENDPOINT'

        opts.on('--app NAME', 'Worker name') do |app|
          options[:app] = app
        end

        opts.on('--locator ADDRESS', 'Locator address') do |endpoint|
          options[:locator] = endpoint
        end

        opts.on('--uuid UUID', 'Worker uuid') do |uuid|
          options[:uuid] = uuid
        end

        opts.on('--endpoint ENDPOINT', 'Worker endpoint') do |endpoint|
          options[:endpoint] = endpoint
        end

        opts.on('--protocol VERSION', Integer, 'Worker protocol version') do |protocol|
          options[:protocol] = protocol
        end

        opts.on_tail('--version', 'Show version the Framework version and exit') do
          puts Cocaine::VERSION.join('.')
          exit
        end
      end.parse!

      Cocaine::LOG.debug "Options: #{options}"
      if options.empty? or options.any? { |option, value| value.nil? }
        Cocaine::LOG.error "Some options aren't specified, but should be. "\
        "Probably, you're trying to start your application manually. Try to restart your app using Cocaine."
        exit Errno::EINVAL
      end

      Default::Locator.endpoints = options[:locator].split(',')

      Cocaine::LOG.debug "Setting default Locator endpoints to #{Default::Locator.endpoints}"
      return Worker.new(options)
    end
  end

  class Rack
    def self.on(event)
      worker = Cocaine::WorkerFactory.create

      worker.on :http do |res, req|
        id, payload = req.recv
        Cocaine::LOG.debug "After receive: '#{{:id => id, :payload => payload}}'"

        case id
          when :write
            method, url, version, headers, body = MessagePack::unpack payload
            Cocaine::LOG.debug "After unpack: '#{id}, #{[method, url, version, headers, body]}'"

            env = Hash[*headers.flatten]
            parsed_url = URI.parse("http://#{env['Host']}#{url}")
            default_host = parsed_url.hostname  || 'localhost'
            default_port = parsed_url.port      || '80'

            # noinspection RubyStringKeysInHashInspection
            env.update(
                {
                    'GATEWAY_INTERFACE' => 'CGI/1.1',
                    'PATH_INFO'         => parsed_url.path  || '',
                    'QUERY_STRING'      => parsed_url.query || '',
                    'REMOTE_ADDR'       => '::1',
                    'REMOTE_HOST'       => 'localhost',
                    'REQUEST_METHOD'    => method,
                    'REQUEST_URI'       => url,
                    'SCRIPT_NAME'       => '',
                    'SERVER_NAME'       => default_host,
                    'SERVER_PORT'       => default_port.to_s,
                    'SERVER_PROTOCOL'   => "HTTP/#{version}",
                    'rack.version'      => [1, 5],
                    'rack.input'        =>  body,
                    'rack.errors'       => $stderr,
                    'rack.multithread'  => true,
                    'rack.multiprocess' => false,
                    'rack.run_once'     => false,
                    'rack.url_scheme'   => 'http',
                    'HTTP_VERSION'      => "HTTP/#{version}",
                    'REQUEST_PATH'      => parsed_url.path,
                }
            )

            Cocaine::LOG.debug "ENV: #{env}"

            now                        = Time.now
            code, headers, body        = yield env
            headers['X-Response-Took'] = "#{(Time.now - now) * 1e3} ms"
            res.write MessagePack.pack [code, headers.to_a]
            body.each do |item|
              res.write MessagePack.pack item
            end

            body.close if body.respond_to?(:close)
          when :error
          when :choke
          else
            # Type code here.
        end
      end

      worker.run
      sleep
    end
  end
end
