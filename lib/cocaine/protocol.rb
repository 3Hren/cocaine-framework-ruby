require 'msgpack'

require 'cocaine/namespace'

module RPC
  HANDSHAKE = 0
  HEARTBEAT = 1
  TERMINATE = 2
  INVOKE = 3
  CHUNK = 4
  ERROR = 5
  CHOKE = 6
end


class Protocol
  attr_reader :id

  def pack(session)
    [@id, session, content].to_msgpack
  end

  def to_s
    "#{self.class.name}(#{content})"
  end

  protected
  def initialize(id)
    @id = id
  end

  protected
  def content
    []
  end
end


class Handshake < Protocol
  def initialize(uuid)
    super RPC::HANDSHAKE
    @uuid = uuid
  end

  protected
  def content
    [@uuid]
  end
end


class Heartbeat < Protocol
  def initialize
    super RPC::HEARTBEAT
  end
end


class Terminate < Protocol
  attr_reader :errno
  attr_reader :reason

  def initialize(errno, reason)
    super RPC::TERMINATE
    @errno = errno
    @reason = reason
  end

  protected
  def content
    [@errno, @reason]
  end
end


class Invoke < Protocol
  attr_reader :event

  def initialize(event)
    super RPC::INVOKE
    @event = event
  end

  protected
  def content
    [@event]
  end
end


class Chunk < Protocol
  attr_reader :data

  def initialize(data)
    super RPC::CHUNK
    @data = data
  end

  protected
  def content
    [@data]
  end
end


class Error < Protocol
  attr_reader :errno
  attr_reader :reason

  def initialize(errno, reason)
    super RPC::ERROR
    @errno = errno
    @reason = reason
  end

  protected
  def content
    [@errno, @reason]
  end
end


class Choke < Protocol
  def initialize
    super RPC::CHOKE
  end
end


class Cocaine::ProtocolFactory
  def self.create(id, data)
    case id
      when RPC::HANDSHAKE
        Handshake.new *data
      when RPC::HEARTBEAT
        Heartbeat.new *data
      when RPC::TERMINATE
        Terminate.new *data
      when RPC::INVOKE
        Invoke.new *data
      when RPC::CHUNK
        Chunk.new *data
      when RPC::ERROR
        Error.new *data
      when RPC::CHOKE
        Choke.new *data
      else
        raise "unexpected message id: #{id}"
    end
  end
end


class ChokeEvent < Exception
end