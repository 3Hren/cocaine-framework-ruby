require 'em-synchrony'
require 'logger'

require 'cocaine/synchrony/service'

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG


class Hook
  attr_reader :callbacks
  def initialize
    @callbacks = {
        :connected => lambda {},
        :message => {}
    }
  end

  def connected(&block)
    @callbacks[:connected] = block
  end

  def message(request, &block)
    @callbacks[:message][request] = block
  end
end


class CocaineRuntimeMock
  module Server
    def initialize(name, responses=nil, hook=nil, options={})
      $log.debug "new connection for '#{name}'"
      @name = name
      @responses = responses || {}
      @hook = hook || Hook.new
      @options = options
    end

    def post_init
      @hook.callbacks[:connected].call
    end

    def receive_data(data)
      unpacker ||= MessagePack::Unpacker.new
      unpacker.feed_each data do |chunk|
        id, session, data = chunk
        $log.debug "received message: [#{id}, #{session}, #{data}]"

        if @hook.callbacks[:message].has_key? chunk
          response = @hook.callbacks[:message][chunk].call
          send_response session, response
        elsif @responses.has_key? chunk
          response = @responses[chunk]
          send_response session, response
        end
      end
    end

    private
    def send_response(session, response)
      $log.debug "iterating over response: #{response}"
      response.each do |chunk|
        if chunk.is_a? Error
          send_data chunk.pack session
        else
          send_data (Chunk.new chunk.to_msgpack).pack session
        end
      end
      send_data Choke.new.pack session
    end
  end

  def initialize(options = {})
    options = {:host => 'localhost', :port => 10053}.merge(options)

    @host = options[:host]
    @port = options[:port]

    @services = {}
    @responses = {}
    @hooks = {}

    @servers = []

    register 'locator', 0, endpoint: [@host, @port], version: 1, api: {}
  end

  def register(name, session, options={})
    raise "service '#{name}' already registered" if @services.has_key? name

    $log.debug "registering '#{name}' service"

    options = {endpoint: ['localhost', 0], version: 1, api: {}}.merge options
    @services[name] = options

    on 'locator',
       [0, session, [name]],
       [[options[:endpoint], options[:version], options[:api]]]
  end

  def on(name, request, response)
    @responses[name] ||= {}
    @responses[name][request] = response
  end

  def when(name)
    @hooks[name] ||= Hook.new
  end

  def run
    @services.each do |name, options|
      $log.debug "starting '#{name}' service at #{options[:endpoint]}"
      sig = EM::start_server *options[:endpoint], Server, name, @responses[name], @hooks[name], options
      @servers.push sig
    end
  end

  def stop
    @servers.each do |sig|
      EM.stop_server sig
    end
  end
end