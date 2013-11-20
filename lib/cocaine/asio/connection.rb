require 'logger'
require 'eventmachine'

require 'cocaine/dispatcher'
require 'cocaine/decoder'
require 'cocaine/protocol'


class Cocaine::Connection < EventMachine::Connection
  class HookManager
    def initialize
      @hooks = {}
    end

    def on(type, &block)
      @hooks[type] = block
    end

    def clear
      @hooks.clear
    end

    def call(type, *args)
      @hooks[type].call *args if @hooks.has_key? type
    end
  end

  attr_reader :state, :hooks

  def initialize(decoder=nil)
    @decoder = decoder || Cocaine::Decoder.new
    @state = :connecting
    @hooks = HookManager.new
  end

  def connection_completed
    @state = :connected
    @hooks.call :connected
  end

  def unbind
    @state = :disconnected
    @hooks.call :disconnected, error?
  end

  def receive_data(raw_data)
    @decoder.feed(raw_data) do |id, session, data|
      message = Cocaine::ProtocolFactory.create(id, data)
      $log.debug "received: [#{session}] #{message}"
      @hooks.call :message, session, message
    end
  end
end