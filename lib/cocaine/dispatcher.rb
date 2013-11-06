require 'protocol'
require_relative '../channel_manager'

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG


class Cocaine::Dispatcher
  def initialize(conn)
    @conn = conn
    @conn.on_message do |session, message|
      process session, message
    end

    @channels = Cocaine::ChannelManager.new
  end

  def process(session, message)
    raise NotImplementedError
  end
end


class Cocaine::ClientDispatcher < Cocaine::Dispatcher
  def process(session, message)
    channel = @channels[session]
    case message.id
      when RPC::CHUNK
        channel.trigger unpack_chunk message.data
      when RPC::ERROR
        channel.error [message.errno, message.reason]
      when RPC::CHOKE
        channel.error message
        channel.close
      else
        raise "unexpected message id: #{id}"
    end
  end

  def invoke(method_id, *data)
    $log.debug("invoking #{method_id} with #{data}")
    session, channel = @channels.create
    message = MessagePack::pack([method_id, session, data])
    @conn.send_data message
    channel
  end

  :private
  def unpack_chunk(data)
    if data.kind_of?(Array)
      data = data.join(',')
    end
    MessagePack.unpack(data)
  end
end


class Cocaine::WorkerDispatcher < Cocaine::Dispatcher
  def initialize(worker, conn)
    super conn
  end

  def process(session, message)
    case message.id
      when RPC::HEARTBEAT
        @health.breath()
      when RPC::TERMINATE
        #send Terminate.new(errno, reason), session
        pass
      when RPC::INVOKE
      when RPC::CHUNK
      when RPC::ERROR
      when RPC::CHOKE
        pass
      else
        raise "unexpected message id: #{id}"
    end
  end

  def send_handshake(session)
    send Handshake.new, session
  end

  def send_heartbeat(session)
    send Heartbeat.new, session
  end

  :private
  def send(message, session)
    @conn.send_data message.pack(session)
  end
end